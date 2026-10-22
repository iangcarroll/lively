package sh.ian.lively.model

import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import sh.ian.lively.net.BrokerTranslationException
import sh.ian.lively.net.FallbackTranslator
import sh.ian.lively.net.MistralTranslator
import sh.ian.lively.net.OnDeviceTranslationException
import sh.ian.lively.net.OnDeviceTranslator
import sh.ian.lively.net.RegionProber
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.net.SpeechEngine
import sh.ian.lively.net.SpeechEngineStatus
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.SpeechSegment
import sh.ian.lively.net.TranslationException
import sh.ian.lively.net.TranslationService
import java.io.IOException

/** What the store needs from the platform: the mic, its permission, and the screen. */
interface ConversationHost {
    /** Asks for the mic if needed; true once it's granted. */
    suspend fun requestMicPermission(): Boolean
    /** Starts capture. Throws when there's no usable mic. */
    @Throws(IOException::class)
    fun startMic(onChunk: (ByteArray, Float) -> Unit, onInterrupted: () -> Unit)
    fun stopMic()
    fun keepScreenAwake(awake: Boolean)
}

sealed interface ConnectionStatus {
    data object Idle : ConnectionStatus
    data object Connecting : ConnectionStatus
    data object Live : ConnectionStatus
    data object Reconnecting : ConnectionStatus
    data object Offline : ConnectionStatus
    data class Failed(val message: String) : ConnectionStatus
}

/**
 * Drives a live conversation: mic → speech engine → turns → translation.
 * Lives on the main thread; [scope] must dispatch there.
 *
 * The engine comes from the provider chosen in Settings. Engines that only
 * transcribe report deltas and turn boundaries, and turns are translated
 * here with a [TranslationService]. Engines that translate by themselves
 * report whole segments, which map one-to-one onto utterances.
 */
class ConversationStore(
    private val settings: AppSettings,
    private val scope: CoroutineScope,
    private val host: ConversationHost,
    private val keyProvider: SonioxKeyProvider? = null,
    /** DeepSeek through the key broker, for typed text; null without a broker. */
    private val brokerTranslator: TranslationService? = null,
    demo: Boolean = false,
    /** Builds the engine; tests swap in a fake. */
    private val makePipeline: (SpeechProvider) -> SpeechPipeline = { it.makePipeline(settings) },
) {
    val utterances = mutableStateListOf<Utterance>()
    var isListening by mutableStateOf(false)
        private set
    var status by mutableStateOf<ConnectionStatus>(ConnectionStatus.Idle)
        private set
    var isOnline by mutableStateOf(true)
        private set
    /** Smoothed mic level for the meter, 0…1. */
    var level by mutableFloatStateOf(0f)
        private set
    var alert by mutableStateOf<String?>(null)

    /** Turns with something to show: not empty, and not only filler words. */
    val visibleUtterances: List<Utterance> by derivedStateOf { utterances.filter { it.hasContent } }

    /** The languages of the turns in [utterances]. */
    private var languages = settings.languages
    private var engine: SpeechEngine? = null
    private var translator: TranslationService? = null

    /** The turn currently receiving transcript text. */
    private var current: Utterance? = null
    private val translations = mutableMapOf<String, Job>()
    private val debounces = mutableMapOf<String, Job>()
    private var silenceTimer: Job? = null
    private var transcriberStatus: SpeechEngineStatus = SpeechEngineStatus.Idle
    /** Utterances of recent segments from a translating engine, by segment id. */
    private val segmentUtterances = mutableMapOf<Int, Utterance>()
    /** Utterances of segments from a catch-up session, by segment id. */
    private val catchUpUtterances = mutableMapOf<Int, Utterance>()
    /** Where speech from the last dropout belongs in [utterances]. */
    private var dropoutIndex: Int? = null
    private val demo: DemoConversation? = if (demo) DemoConversation(scope) else null
    /** Ends a paused engine's session once it's been idle for [WARM_PAUSE_MS]. */
    private var idleTeardown: Job? = null
    /** Settings changed while listening, so the engine isn't kept warm. */
    private var engineIsStale = false

    /** One channel keeps chunks in order on their way from the capture thread. */
    private val chunks = Channel<Pair<ByteArray, Float>>(500, BufferOverflow.DROP_OLDEST)

    init {
        if (demo) translator = DemoTranslator()
        scope.launch {
            for ((chunk, level) in chunks) {
                if (!isListening) continue
                engine?.send(chunk)
                this@ConversationStore.level = this@ConversationStore.level * 0.6f + level * 0.4f
            }
        }
        regionProber?.probe()
        prefetchKey()
    }

    /**
     * Re-measures Soniox regions and gets a key ready when the app comes to
     * the foreground, so tapping the mic doesn't wait on the key broker.
     */
    fun didBecomeActive() {
        regionProber?.probe()
        prefetchKey()
    }

    /**
     * The app went to the background, where Android won't let it keep the mic:
     * stop, and don't keep a session warm.
     */
    fun didEnterBackground() {
        stopListening()
        releaseEngine()
    }

    /** The network came or went, or moved to another interface. */
    fun setNetwork(online: Boolean, changedInterface: Boolean) {
        if (online && isOnline && changedInterface) engine?.networkPathChanged()
        // A new interface or route can change which region is closest.
        if (online && (changedInterface || !isOnline)) regionProber?.probe(minimumIntervalMs = 5_000)
        if (online == isOnline) return
        isOnline = online
        engine?.networkAvailable = online
        refreshStatus()
    }

    private fun prefetchKey() {
        if (regionProber == null) return
        keyProvider?.prefetch()
    }

    /** Set when Soniox keys come from the broker, which mints in any of its regions. */
    private val regionProber: RegionProber?
        get() {
            if (demo != null || settings.providerID != SpeechProviders.SONIOX_ID) return null
            if (settings.credential(SpeechProviders.sonioxCredential(true)).isNotEmpty()) return null
            return keyProvider?.regions
        }

    // region Listening

    fun toggleListening() = if (isListening) stopListening() else startListening()

    fun startListening() {
        if (isListening) return
        demo?.let {
            isListening = true
            transcriberStatus = SpeechEngineStatus.Live
            refreshStatus()
            it.play(::handle)
            return
        }
        val provider = settings.provider
        if (!settings.hasCredentials) {
            val names = provider.credentials.joinToString(" and ") { it.name }
            alert = "Add your $names in Settings to start."
            return
        }
        scope.launch {
            if (!host.requestMicPermission()) {
                alert = "Lively needs microphone access. You can turn it on in Settings › Apps › Lively › Permissions."
                return@launch
            }
            if (isListening) return@launch
            isListening = true
            host.keepScreenAwake(true)
            // Connect while the mic starts up. Audio that arrives before the
            // session is ready waits in the socket's backlog.
            startEngine(provider)
            try {
                host.startMic(
                    onChunk = { chunk, level -> chunks.trySend(chunk to level) },
                    onInterrupted = {
                        stopListening()
                        alert = "The microphone stopped. Tap the mic to start again."
                    },
                )
            } catch (e: IOException) {
                stopListening()
                releaseEngine()
                alert = e.message ?: "No microphone is available."
            }
        }
    }

    private fun startEngine(provider: SpeechProvider) {
        engine?.let { engine ->
            // Still warm from the last pause.
            idleTeardown?.cancel()
            idleTeardown = null
            engine.resume()
            refreshStatus()
            return
        }
        val pipeline = makePipeline(provider)
        translator = pipeline.translator
        val engine = pipeline.engine
        engine.onEvent = ::handle
        engine.onStatus = { status ->
            transcriberStatus = status
            if (isListening) {
                refreshStatus()
            } else if (status is SpeechEngineStatus.Failed) {
                // A paused session failed; start over next time.
                releaseEngine()
            }
        }
        engine.networkAvailable = isOnline
        this.engine = engine
        engine.start()
    }

    fun stopListening() {
        if (!isListening) return
        isListening = false
        demo?.stop()
        if (demo == null) host.stopMic()
        pauseEngine()
        level = 0f
        host.keepScreenAwake(false)
        finalizeCurrent()
        refreshStatus()
    }

    /**
     * Keeps the engine's session open for [WARM_PAUSE_MS], so listening again
     * right away doesn't reconnect.
     */
    private fun pauseEngine() {
        val engine = engine ?: return
        if (engineIsStale) {
            releaseEngine()
            return
        }
        engine.pause()
        idleTeardown?.cancel()
        idleTeardown = scope.launch {
            delay(WARM_PAUSE_MS)
            releaseEngine()
        }
    }

    /**
     * Settings can change the provider or key, which a warm session can't
     * pick up, so the next start builds a new engine.
     */
    fun settingsDidClose() {
        if (languages != settings.languages) {
            // Turns in the old languages don't fit the new pair, and the
            // engine listens for the old one.
            languages = settings.languages
            stopListening()
            clear()
        }
        if (isListening) engineIsStale = true else releaseEngine()
        prefetchKey()
    }

    /** Closes a paused engine's session. */
    private fun releaseEngine() {
        if (isListening) return
        engineIsStale = false
        idleTeardown?.cancel()
        idleTeardown = null
        engine?.stop()
        engine = null
        transcriberStatus = SpeechEngineStatus.Idle
    }

    fun clear() {
        translations.values.forEach { it.cancel() }
        debounces.values.forEach { it.cancel() }
        translations.clear()
        debounces.clear()
        current = null
        segmentUtterances.clear()
        catchUpUtterances.clear()
        dropoutIndex = null
        utterances.clear()
    }

    /**
     * Removes one turn. A translating engine's later updates to that
     * segment go to the removed utterance, so it stays gone; words still
     * arriving for a removed transcript-only turn start a new one.
     */
    fun delete(utterance: Utterance) {
        val index = utterances.indexOfFirst { it === utterance }
        if (index < 0) return
        translations.remove(utterance.id)?.cancel()
        debounces.remove(utterance.id)?.cancel()
        if (current === utterance) current = null
        utterances.removeAt(index)
        dropoutIndex?.let { if (index < it) dropoutIndex = it - 1 }
    }

    /**
     * Replaces a finished turn's transcript, such as a misheard name, and
     * translates it again with the typed-text translator. The old
     * translation stays until the new one is complete.
     */
    fun edit(utterance: Utterance, text: String) {
        val trimmed = text.trim()
        if (!utterance.isFinal || trimmed.isEmpty() || trimmed == utterance.trimmedSource) return
        translations.remove(utterance.id)?.cancel()
        debounces.remove(utterance.id)?.cancel()
        // A translating engine's late update to the segment must not undo the edit.
        segmentUtterances.values.removeAll { it === utterance }
        catchUpUtterances.values.removeAll { it === utterance }
        utterance.setSource(trimmed, language = null)
        utterance.isTyped = true
        utterance.translatedSource = null
        translate(utterance)
    }

    /**
     * Adds a typed turn and translates it. [language] is the typist's
     * language, used when the text doesn't say which of the pair it's in.
     */
    fun submitTyped(text: String, language: Language) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val detected = LanguageDetector.detect(trimmed, languages) ?: if (language in languages) language else languages.first
        val utterance = Utterance(languages, trimmed, detected)
        utterance.isTyped = true
        utterance.isFinal = true
        utterances += utterance
        translate(utterance)
    }

    /**
     * Translates typed turns. Engines that translate speech by themselves
     * don't translate text, so this uses the broker's DeepSeek, falling back
     * to on-device translation; then a Mistral key if there is one.
     */
    private val textTranslator: TranslationService
        get() {
            translator?.let { return it }
            brokerTranslator?.let { return FallbackTranslator(it, onDeviceTranslator) }
            val key = settings.credential(SpeechProviders.mistralCredential)
            if (key.isNotEmpty()) return MistralTranslator(key, settings.translationModel)
            return onDeviceTranslator
        }

    private val onDeviceTranslator by lazy { OnDeviceTranslator() }

    /** True when typed text needs on-device language models. */
    val translatesTypedTextOnDevice: Boolean get() = textTranslator is OnDeviceTranslator

    /** Downloads the on-device models typed text needs, if they aren't there yet. */
    fun prepareTypedTranslation() {
        if (!translatesTypedTextOnDevice) return
        val pair = languages
        scope.launch { runCatching { onDeviceTranslator.prepare(pair) } }
    }

    fun retryTranslation(utterance: Utterance) {
        utterance.translatedSource = null
        translate(utterance)
    }

    // endregion

    // region Transcript events

    /**
     * Wait this long after a turn boundary so the turn's trailing words,
     * which lag behind the boundary event, stay in it.
     */
    private val boundaryDelay: Long get() = engine?.textLagMs ?: 0

    fun handle(event: SpeechEvent) {
        when (event) {
            is SpeechEvent.Text -> {
                val utterance = current ?: Utterance(languages).also {
                    utterances += it
                    current = it
                }
                utterance.append(if (utterance.source.isEmpty()) event.delta.trimStart() else event.delta)
                scheduleTranslation(utterance, delayMs = 280)
                armSilenceFallback()
            }

            SpeechEvent.TurnStarted -> {
                // Close the previous turn once its trailing text has arrived.
                val previous = current
                after(boundaryDelay) { if (previous != null && current === previous) finalizeCurrent() }
            }

            // The speaker has probably finished. Translate now instead of waiting for turn.end.
            SpeechEvent.TurnEagerEnded -> current?.let { scheduleTranslation(it, delayMs = 0) }

            SpeechEvent.TurnResumed -> {}

            SpeechEvent.TurnEnded -> {
                val ending = current
                after(boundaryDelay) { if (ending != null && current === ending) finalizeCurrent() }
            }

            is SpeechEvent.Segment -> apply(event.segment)

            SpeechEvent.SessionReset -> {
                finalizeCurrent()
                dropoutIndex = utterances.size
            }
        }
    }

    /**
     * Shows a segment from an engine that translates by itself. Its
     * translation fills [Utterance.translation] directly.
     */
    private fun apply(segment: SpeechSegment) {
        if (segment.isCatchUp) {
            applyCatchUp(segment)
            return
        }
        val utterance = segmentUtterances[segment.id] ?: run {
            if (segment.source.isBlank()) return
            finalizeCurrent()
            // Earlier segments' translations are complete once a new one starts.
            for (older in segmentUtterances.values) {
                if (older.translationState == TranslationState.Working) older.translationState = TranslationState.Current
            }
            // Keep the last one: its translation can still arrive. Catch-up
            // segments share the id sequence, so ids can skip.
            val last = segmentUtterances.keys.maxOrNull()
            segmentUtterances.keys.retainAll { it == last }
            Utterance(languages).also {
                utterances += it
                segmentUtterances[segment.id] = it
            }
        }

        show(segment, utterance)

        if (segment.isClosed) {
            if (current === utterance) finalizeCurrent() else utterance.isFinal = true
            if (!utterance.hasContent) utterances.remove(utterance)
        } else if (!utterance.isFinal) {
            current = utterance
            armSilenceFallback()
        }
    }

    /**
     * Shows a segment of speech from a dropout where the dropout happened,
     * ahead of whatever was said since.
     */
    private fun applyCatchUp(segment: SpeechSegment) {
        val utterance = catchUpUtterances[segment.id] ?: run {
            if (segment.source.isBlank()) return
            for (older in catchUpUtterances.values) {
                if (older.translationState == TranslationState.Working) older.translationState = TranslationState.Current
            }
            val last = catchUpUtterances.keys.maxOrNull()
            catchUpUtterances.keys.retainAll { it == last }
            Utterance(languages).also {
                it.isLate = true
                val index = minOf(dropoutIndex ?: utterances.size, utterances.size)
                utterances.add(index, it)
                dropoutIndex = index + 1
                catchUpUtterances[segment.id] = it
            }
        }

        show(segment, utterance)
        utterance.isFinal = segment.isClosed
        if (segment.isClosed && !utterance.hasContent) {
            utterances.remove(utterance)
            dropoutIndex = dropoutIndex?.let { maxOf(0, it - 1) }
        }
    }

    private fun show(segment: SpeechSegment, utterance: Utterance) {
        // Detect first, so only Chinese text gets the chosen script; Japanese kanji must not.
        val source = segment.source.trimStart()
        val language = segment.language ?: LanguageDetector.detect(source, languages) ?: utterance.language
        val target = languages.other(language)
        utterance.setSource(convertScript(source, language), language)
        utterance.translation = convertScript(Filler.strip(segment.translation, target), target)
        utterance.translatedSource = utterance.trimmedSource
        utterance.translationState =
            if (segment.isClosed && utterance.translation.isNotEmpty()) TranslationState.Current else TranslationState.Working
    }

    private fun convertScript(text: String, language: Language) =
        if (language == Language.CHINESE) settings.chineseScript.convert(text) else text

    /**
     * Ends the turn if no text and no turn events have arrived for a while,
     * in case turn detection misses a boundary.
     */
    private fun armSilenceFallback() {
        silenceTimer?.cancel()
        silenceTimer = scope.launch {
            delay(3_000)
            engine?.endTurn()
            finalizeCurrent()
        }
    }

    private fun finalizeCurrent() {
        silenceTimer?.cancel()
        val utterance = current ?: return
        current = null
        utterance.isFinal = true
        if (!utterance.hasContent) {
            utterances.remove(utterance)
            return
        }
        if (utterance.needsTranslation) scheduleTranslation(utterance, delayMs = 0)
    }

    // endregion

    // region Translation

    /**
     * Throttles translation while someone is speaking: at most one request
     * in flight per turn, and a new one starts as soon as it finishes if the
     * transcript has grown. Long monologues keep updating instead of waiting
     * for a pause.
     */
    private fun scheduleTranslation(utterance: Utterance, delayMs: Long) {
        if (translations[utterance.id] != null) return
        if (delayMs > 0 && debounces[utterance.id] != null) return
        debounces[utterance.id]?.cancel()
        debounces[utterance.id] = scope.launch {
            if (delayMs > 0) delay(delayMs)
            debounces.remove(utterance.id)
            if (utterance.needsTranslation) translate(utterance)
        }
    }

    private fun translate(utterance: Utterance) {
        val text = utterance.trimmedSource
        val translator = (if (utterance.isTyped) textTranslator else translator) ?: return
        if (text.isEmpty() || translations[utterance.id] != null) return

        val language = utterance.language
        val target = utterance.target
        val context = utterances.takeWhile { it !== utterance }.filter { it.isFinal && it.hasContent }.takeLast(3)
        val script = settings.chineseScript

        utterance.translationState = TranslationState.Working
        translations[utterance.id] = scope.launch {
            var attempt = 0
            while (isActive) {
                // Hold the request until we're back online.
                if (!isOnline) {
                    utterance.translationState = TranslationState.WaitingForNetwork
                    while (!isOnline) delay(250)
                    utterance.translationState = TranslationState.Working
                }
                try {
                    var output = ""
                    // Show tokens as they stream for a first translation. When
                    // revising an existing one, swap in the new text only when
                    // it's complete so the line doesn't flicker.
                    val streamLive = utterance.translation.isEmpty()
                    translator.translate(text, language, target, context, script).collect { token ->
                        output += token
                        if (streamLive) utterance.translation = output
                    }
                    utterance.translation = output.trim()
                    utterance.translatedSource = text
                    utterance.translationState =
                        if (utterance.needsTranslation) TranslationState.Working else TranslationState.Current
                    translations.remove(utterance.id)
                    // The speaker kept talking while we translated; catch up.
                    if (utterance.needsTranslation) translate(utterance)
                    return@launch
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    attempt += 1
                    val permanent = e is OnDeviceTranslationException ||
                        (e as? BrokerTranslationException)?.isPermanent == true ||
                        (e as? TranslationException)?.isPermanent == true
                    if (permanent || attempt >= 4) {
                        utterance.translationState = TranslationState.Failed(e.message ?: "Translation failed")
                        translations.remove(utterance.id)
                        return@launch
                    }
                    delay(400L * (1 shl attempt))
                }
            }
        }
    }

    // endregion

    // region Status

    private fun refreshStatus() {
        if (!isListening) {
            status = ConnectionStatus.Idle
            return
        }
        status = when (val transcriber = transcriberStatus) {
            SpeechEngineStatus.Idle -> ConnectionStatus.Idle
            SpeechEngineStatus.Connecting -> if (isOnline) ConnectionStatus.Connecting else ConnectionStatus.Offline
            SpeechEngineStatus.Live -> ConnectionStatus.Live
            SpeechEngineStatus.Reconnecting -> if (isOnline) ConnectionStatus.Reconnecting else ConnectionStatus.Offline
            is SpeechEngineStatus.Failed -> {
                status = ConnectionStatus.Failed(transcriber.message)
                stopListening()
                releaseEngine()
                alert = transcriber.message
                return
            }
        }
    }

    private fun after(delayMs: Long, action: () -> Unit) {
        scope.launch {
            if (delayMs > 0) delay(delayMs)
            action()
        }
    }

    // endregion

    companion object {
        /**
         * How long a paused session stays open for a quick resume. Soniox bills
         * for the open stream, so this is kept short.
         */
        const val WARM_PAUSE_MS = 60_000L
    }
}
