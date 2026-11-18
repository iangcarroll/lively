package sh.ian.lively.model

import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.audio.NoiseGate
import sh.ian.lively.audio.SpeechPlayer
import sh.ian.lively.net.AutoSpeechSegment
import sh.ian.lively.net.BrokerTranslationException
import sh.ian.lively.net.FallbackTranslator
import sh.ian.lively.net.MistralTranslator
import sh.ian.lively.net.OnDeviceTranslationException
import sh.ian.lively.net.OnDeviceTranslator
import sh.ian.lively.net.RegionProber
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.net.SonioxSpeaker
import sh.ian.lively.net.SpeechEngine
import sh.ian.lively.net.SpeechEngineStatus
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.SpeechSegment
import sh.ian.lively.net.TranslationException
import sh.ian.lively.net.TranslationService
import java.io.IOException
import java.util.UUID

/** What the store needs from the platform: the mic, its permission, and the screen. */
interface ConversationHost {
    /** Asks for the mic if needed; true once it's granted. */
    suspend fun requestMicPermission(): Boolean
    /** Starts capture, passing each chunk with its level in dBFS. Throws when there's no usable mic. */
    @Throws(IOException::class)
    fun startMic(onChunk: (ByteArray, Float) -> Unit, onInterrupted: () -> Unit)
    fun stopMic()
    fun keepScreenAwake(awake: Boolean)
    /** Plays spoken translations, for speech-to-speech mode. */
    fun makeSpeechPlayer(): SpeechPlayer = SpeechPlayer(audioManager = null)
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
    /** The time in milliseconds; tests move it. */
    private val now: () -> Long = System::currentTimeMillis,
) {
    val utterances = mutableStateListOf<Utterance>()
    var isListening by mutableStateOf(false)
        private set
    var status by mutableStateOf<ConnectionStatus>(ConnectionStatus.Idle)
        private set
    var isOnline by mutableStateOf(true)
        private set
    /** Listening, but the speech service isn't connected yet, so nobody is heard. */
    val isConnecting: Boolean
        get() = isListening && (status == ConnectionStatus.Connecting || status == ConnectionStatus.Reconnecting)
    /** Smoothed mic level for the meter, 0…1. */
    var level by mutableFloatStateOf(0f)
        private set
    /** The noise gate is letting the mic through: someone is close enough to translate. */
    var isHearing by mutableStateOf(false)
        private set
    var alert by mutableStateOf<String?>(null)

    /** Turns with something to show: not empty, and not only filler words. */
    val visibleUtterances: List<Utterance> by derivedStateOf { utterances.filter { it.hasContent } }

    /** The languages of the turns in [utterances]. */
    var languages = settings.languages
        private set
    private var configuredAutomaticMode by mutableStateOf(settings.usesAutomaticLanguageDetection)
    private var configuredListenerLanguage by mutableStateOf(settings.speechListenerLanguage)
    private var automaticSessionID = UUID.randomUUID().toString()
    private var automaticLastActivity = now()
    private val automaticSegmentUtterances = mutableMapOf<Int, Utterance>()
    private val automaticCatchUpUtterances = mutableMapOf<Int, Utterance>()
    var detectedPartnerLanguage by mutableStateOf<Language?>(null)
        private set
    private var pendingPartnerLanguage: Language? = null
    private var pendingPartnerConfirmations = 0
    private val automaticLanguageEvidence = mutableSetOf<String>()
    val isAutomaticLanguageMode: Boolean get() = configuredAutomaticMode
    val listenerLanguage: Language
        get() = if (isAutomaticLanguageMode) configuredListenerLanguage else settings.speechListenerLanguage
    private var engine: SpeechEngine? = null
    /** The provider [engine] was built from, so a different one isn't resumed. */
    private var engineProviderID: String? = null
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
    /** A press can end while permission or audio startup is still pending. */
    private var listeningStart: Job? = null
    /** Ends a paused engine's session once it's been idle for [WARM_PAUSE_MS]. */
    private var idleTeardown: Job? = null
    /** Settings changed while listening, so the engine isn't kept warm. */
    private var engineIsStale = false
    /**
     * Speech-to-speech: reads translations into the second language aloud.
     * Made when first needed.
     */
    private var speaker: SonioxSpeaker? = null
    /**
     * Characters of each turn's translation already sent to the speaker;
     * [Int.MAX_VALUE] once the whole turn has been.
     */
    private val spoken = mutableMapOf<String, Int>()
    /** Speaks a translation's unpunctuated tail once it stops growing. */
    private val speechFlushes = mutableMapOf<String, Job>()
    /** Turns from before speech-to-speech was switched on aren't read out. */
    private var speakingSince: Long? = if (settings.speaksTranslations) System.currentTimeMillis() else null

    /** Sends quiet chunks as silence, per the pickup range in Settings. */
    private val gate = NoiseGate()

    /** One channel keeps chunks in order on their way from the capture thread. */
    private val chunks = Channel<Pair<ByteArray, Float>>(500, BufferOverflow.DROP_OLDEST)

    init {
        if (demo) translator = DemoTranslator()
        scope.launch {
            for ((chunk, decibels) in chunks) {
                if (!isListening) continue
                // Gated chunks go as silence rather than not at all, so the
                // engine still hears the pause and ends the turn.
                // While a translation is read aloud the mic would hear it and
                // translate it back, so it sends silence (but not into headphones).
                val heard = gate.process(decibels, settings.pickupRange) && speaker?.player?.mutesMic != true
                isHearing = heard
                engine?.send(if (heard) chunk else ByteArray(chunk.size))
                level = level * 0.6f + MicCapture.meterLevel(decibels) * 0.4f
            }
        }
        regionProber?.probe()
        prefetchKey()
    }

    /**
     * Opens a speech session as the app launches, so the first tap on the
     * mic is live at once instead of waiting on the connect. It's held like
     * a pause and closed after [WARM_PAUSE_MS] if nobody starts listening. Call
     * it once onboarding is done, which asks for the mic and may change the
     * languages. Only the first call in a launch prewarms.
     */
    fun prewarm() {
        synchronizeLanguages()
        if (didPrewarm || demo != null || engine != null || isListening || !settings.hasCredentials) return
        didPrewarm = true
        makeEngine(settings.provider).prewarm()
        scheduleIdleTeardown()
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

    /** A separate lookup should not receive late speech from a warm session. */
    fun pauseForAddressLookup() {
        stopListening()
        releaseEngine()
        speechRoutingDidChange()
    }

    /** The network came or went, or moved to another interface. */
    fun setNetwork(online: Boolean, changedInterface: Boolean) {
        if (online && isOnline && changedInterface) engine?.networkPathChanged()
        // A new interface or route can change which region is closest.
        if (online && (changedInterface || !isOnline)) regionProber?.probe(minimumIntervalMs = 5_000)
        if (online == isOnline) return
        isOnline = online
        engine?.networkAvailable = online
        if (isAutomaticLanguageMode) {
            if (!online) {
                val active = translations.keys.toSet()
                translations.values.forEach { it.cancel() }
                translations.clear()
                for (utterance in utterances) {
                    if (utterance.id in active && utterance.needsTranslation) {
                        utterance.translationState = TranslationState.WaitingForNetwork
                    }
                }
            } else {
                for (utterance in utterances.toList()) {
                    if (utterance.translationState == TranslationState.WaitingForNetwork && utterance.needsTranslation) {
                        translate(utterance)
                    }
                }
            }
        }
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

    fun toggleListening() = if (isListening || listeningStart != null) stopListening() else startListening()

    fun startListening() {
        if (isListening || listeningStart != null) return
        synchronizeLanguages()
        expireAutomaticContext()
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
        // Lazy, so a start that finishes at once still finds itself here.
        val start = scope.launch(start = CoroutineStart.LAZY) {
            val permitted = host.requestMicPermission()
            listeningStart = null
            if (!permitted) {
                alert = "Lively needs microphone access. You can turn it on in Settings › Apps › Lively › Permissions."
                return@launch
            }
            if (isListening) return@launch
            isListening = true
            gate.reset()
            // Someone wants to talk: cut off a translation being read out.
            speaker?.player?.stop()
            host.keepScreenAwake(true)
            // Connect while the mic starts up. Audio that arrives before the
            // session is ready waits in the socket's backlog.
            startEngine(provider)
            try {
                host.startMic(
                    onChunk = { chunk, decibels -> chunks.trySend(chunk to decibels) },
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
        listeningStart = start
        start.start()
    }

    private fun startEngine(provider: SpeechProvider) {
        synchronizeLanguages()
        dropoutIndex = utterances.size
        engine?.let { engine ->
            if (engineProviderID == provider.id && !engineIsStale) {
                // Still warm from the last pause.
                idleTeardown?.cancel()
                idleTeardown = null
                engine.resume()
                refreshStatus()
                return
            }
            // A session built for another provider or settings can't be reused.
            this.engine = null
            engineProviderID = null
            engine.stop()
        }
        makeEngine(provider).start()
    }

    private fun makeEngine(provider: SpeechProvider): SpeechEngine {
        retireNativeSegments()
        engineIsStale = false
        val pipeline = makePipeline(provider)
        translator = pipeline.translator
        val engine = pipeline.engine
        engine.onEvent = { event -> if (this.engine === engine) handle(event) }
        engine.onStatus = status@{ status ->
            if (this.engine !== engine) return@status
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
        engineProviderID = provider.id
        return engine
    }

    fun stopListening() {
        listeningStart?.cancel()
        listeningStart = null
        if (!isListening) return
        isListening = false
        demo?.stop()
        if (demo == null) host.stopMic()
        pauseEngine()
        level = 0f
        isHearing = false
        host.keepScreenAwake(false)
        finalizeStoppedTurn()
        refreshStatus()
    }

    private fun finalizeStoppedTurn() {
        val ending = current
        if (engine?.drainsTextOnPause != true || ending == null) {
            finalizeCurrent()
            return
        }
        silenceTimer?.cancel()
        silenceTimer = scope.launch {
            delay(10_000)
            if (current === ending) finalizeCurrent()
        }
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
        scheduleIdleTeardown()
    }

    private fun scheduleIdleTeardown() {
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
        synchronizeLanguages()
        // The Soniox key may have changed.
        speaker?.stop()
        speaker = null
        speechSettingChanged()
        if (isListening) engineIsStale = true else releaseEngine()
        prefetchKey()
    }

    /**
     * Turns in the old languages don't fit the new ones, and the engine
     * listens for the old ones.
     */
    private fun synchronizeLanguages() {
        val automatic = settings.usesAutomaticLanguageDetection
        val listener = settings.speechListenerLanguage
        val changed = automatic != configuredAutomaticMode ||
            (automatic && listener != configuredListenerLanguage) ||
            (!automatic && languages != settings.languages)
        if (!changed) return
        stopListening()
        releaseEngine()
        languages = settings.languages
        configuredAutomaticMode = automatic
        configuredListenerLanguage = listener
        clear()
    }

    /** Closes a paused engine's session. */
    private fun releaseEngine() {
        if (isListening) return
        engineIsStale = false
        idleTeardown?.cancel()
        idleTeardown = null
        val previous = engine
        engine = null
        engineProviderID = null
        previous?.stop()
        retireNativeSegments()
        // The demo has no engine to bring its translator back.
        if (demo == null) translator = null
        transcriberStatus = SpeechEngineStatus.Idle
    }

    fun clear() {
        // A new automatic conversation must not receive the previous socket's
        // delayed language evidence or reuse its segment identifiers.
        val resumeAutomatic = isAutomaticLanguageMode && isListening
        if (isAutomaticLanguageMode && engine != null) {
            stopListening()
            releaseEngine()
        }
        speaker?.stop()
        spoken.clear()
        speechFlushes.values.forEach { it.cancel() }
        speechFlushes.clear()
        translations.values.forEach { it.cancel() }
        debounces.values.forEach { it.cancel() }
        translations.clear()
        debounces.clear()
        current = null
        segmentUtterances.clear()
        catchUpUtterances.clear()
        dropoutIndex = null
        utterances.clear()
        resetAutomaticConversation()
        if (resumeAutomatic) startListening()
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
        speechFlushes.remove(utterance.id)?.cancel()
        spoken[utterance.id] = Int.MAX_VALUE
        if (current === utterance) {
            current = null
            silenceTimer?.cancel()
            silenceTimer = null
        }
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
        // Keep the native binding so late updates are ignored instead of
        // creating a second row for the reader's corrected turn.
        utterance.setSource(trimmed, language = if (utterance.isAutomatic) utterance.sourceLanguage else null)
        // The correction belongs to the reader even when retry must wait for
        // an unidentified source language. Late native results cannot undo it.
        utterance.isTyped = true
        utterance.isAutomaticSourceFinal = true
        utterance.isExplicitTranslationRequest = true
        utterance.suppressesAutomaticSpeech = false
        utterance.translatedSource = null
        retryTranslation(utterance)
    }

    /**
     * Adds a typed turn and translates it. [language] is the typist's
     * language, used when the text doesn't say which of the pair it's in.
     */
    fun submitTyped(text: String, language: Language) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        if (isAutomaticLanguageMode) {
            expireAutomaticContext()
            automaticLastActivity = now()
            val hint = if (language in Language.SONIOX) language else listenerLanguage
            val source = LanguageDetector.detect(trimmed, among = Language.SONIOX) ?: hint
            val target = if (source == listenerLanguage) detectedPartnerLanguage else listenerLanguage
            val utterance = Utterance.automatic(trimmed, source, target, listenerLanguage, automaticSessionID)
            utterance.isTyped = true
            utterance.isFinal = true
            utterance.isAutomaticSourceFinal = true
            if (target == null) {
                utterance.wasAwaitingPartner = true
                utterance.suppressesAutomaticSpeech = true
                utterance.translationState = TranslationState.AwaitingPartner
            }
            utterances += utterance
            translate(utterance)
            return
        }
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
        // Automatic has nothing to prepare until it has heard the other language.
        val pair = if (isAutomaticLanguageMode) {
            LanguagePair(listenerLanguage, detectedPartnerLanguage ?: return)
        } else {
            languages
        }
        scope.launch { runCatching { onDeviceTranslator.prepare(pair) } }
    }

    fun retryTranslation(utterance: Utterance) {
        if (utterance.isAutomatic) {
            val source = utterance.sourceLanguage
            if (source == null) {
                utterance.translationState = TranslationState.AwaitingPartner
                return
            }
            if (utterance.target == null) {
                if (source != utterance.listenerLanguage) {
                    utterance.bindAutomaticTarget(utterance.listenerLanguage)
                } else {
                    detectedPartnerLanguage?.let { utterance.bindAutomaticTarget(it) }
                }
            }
            utterance.isExplicitTranslationRequest = true
            utterance.isAutomaticSourceFinal = true
            utterance.suppressesAutomaticSpeech = false
        }
        // A native session may end before its translation arrives. Retry
        // through text translation without allowing a late native overwrite.
        utterance.isTyped = true
        utterance.translatedSource = null
        utterance.translatedLanguage = null
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
                val previousLanguage = utterance.language
                utterance.append(if (utterance.source.isEmpty()) event.delta.trimStart() else event.delta)
                val changed = utterance.language != previousLanguage
                if (changed) invalidateTranslation(utterance)
                scheduleTranslation(utterance, delayMs = if (changed) 0 else 280)
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

            is SpeechEvent.AutoSegment -> applyAutomatic(event.segment)

            SpeechEvent.SessionReset -> {
                finalizeCurrent()
                failMissingSegmentTranslations()
                for (utterance in automaticSegmentUtterances.values + automaticCatchUpUtterances.values) {
                    settleInterruptedAutomaticTurn(utterance)
                }
                dropoutIndex = utterances.size
            }
        }
    }

    /**
     * Discovery belongs to this conversation, not the saved manual pair.
     * Clearing or expiring it leaves completed history in its original direction.
     */
    private fun resetAutomaticConversation() {
        val previous = automaticSessionID
        for (utterance in utterances) {
            if (utterance.automaticSessionID != previous) continue
            translations.remove(utterance.id)?.cancel()
            debounces.remove(utterance.id)?.cancel()
            speechFlushes.remove(utterance.id)?.cancel()
            if (utterance.translationState == TranslationState.Working ||
                utterance.translationState == TranslationState.WaitingForNetwork
            ) {
                utterance.translationState =
                    if (utterance.translation.isEmpty()) TranslationState.Failed(INTERRUPTED) else TranslationState.Current
            }
        }
        automaticSessionID = UUID.randomUUID().toString()
        automaticLastActivity = now()
        detectedPartnerLanguage = null
        pendingPartnerLanguage = null
        pendingPartnerConfirmations = 0
        automaticLanguageEvidence.clear()
        automaticSegmentUtterances.clear()
        automaticCatchUpUtterances.clear()
    }

    /**
     * A later encounter should discover its own language, while a brief mic
     * pause or background interruption keeps the current conversation intact.
     */
    private fun expireAutomaticContext() {
        if (!isAutomaticLanguageMode || now() - automaticLastActivity <= CONTEXT_EXPIRY_MS) return
        resetAutomaticConversation()
    }

    private fun applyAutomatic(segment: AutoSpeechSegment) {
        if (!isAutomaticLanguageMode) return
        val source = segment.source.trimStart()
        val language = segment.language?.takeIf { it in Language.SONIOX }
        val invalidLanguage = segment.language != null && language == null
        val invalidTarget = segment.target != null && segment.target != listenerLanguage
        val nativeTarget =
            if (!invalidLanguage && segment.target == listenerLanguage && language != listenerLanguage) listenerLanguage else null
        val hasNativeTranslation = nativeTarget != null && segment.translation.isNotBlank()
        if (!segment.isCatchUp && source.isNotBlank()) {
            expireAutomaticContext()
            automaticLastActivity = now()
        }
        val existing = if (segment.isCatchUp) automaticCatchUpUtterances[segment.id] else automaticSegmentUtterances[segment.id]
        val utterance = if (existing != null) {
            // Keep deleted and explicitly corrected rows retired even if their
            // provider segment still has a final update in flight.
            if (utterances.none { it === existing } || existing.isTyped) return
            existing
        } else {
            if (source.isBlank() && !hasNativeTranslation) return
            // A provisional reply may follow a newly arriving language in
            // the same provider turn. Capture its destination at completion.
            Utterance.automatic(source, language, nativeTarget, listenerLanguage, automaticSessionID).also {
                it.isLate = segment.isCatchUp
                if (segment.isCatchUp) {
                    val index = minOf(dropoutIndex ?: utterances.size, utterances.size)
                    utterances.add(index, it)
                    dropoutIndex = index + 1
                    automaticCatchUpUtterances[segment.id] = it
                } else {
                    utterances += it
                    automaticSegmentUtterances[segment.id] = it
                }
            }
        }
        val resolvedLanguage = language ?: utterance.sourceLanguage
        if (!hasNativeTranslation && utterance.translation.isNotEmpty() && !utterance.isTyped) {
            // Native snapshots replace a volatile preview; an empty update
            // retracts it. Confirmed native text remains in every snapshot.
            invalidateTranslation(utterance)
            utterance.translation = ""
            utterance.translatedSource = null
            utterance.translatedLanguage = null
            utterance.translatedTarget = null
            if (nativeTarget == null) utterance.correctAutomaticTarget(null)
        }
        if (resolvedLanguage != null && resolvedLanguage != utterance.sourceLanguage) {
            invalidateTranslation(utterance)
            utterance.correctAutomaticTarget(nativeTarget)
            utterance.isAutomaticSourceFinal = false
        }
        utterance.setSource(resolvedLanguage?.let { convertScript(source, it) } ?: source, resolvedLanguage)
        if (nativeTarget != null) {
            utterance.bindAutomaticTarget(nativeTarget)
        } else if (resolvedLanguage == listenerLanguage && utterance.target == null &&
            segment.isSourceFinal && segment.languageIsFinal
        ) {
            detectedPartnerLanguage?.let { utterance.bindAutomaticTarget(it) }
        }
        utterance.isAutomaticSourceFinal = utterance.isAutomaticSourceFinal ||
            (segment.isSourceFinal && segment.languageIsFinal && language != null)
        utterance.hasFinalAutomaticLanguage = segment.languageIsFinal && language != null
        utterance.waitsForAutomaticPartner =
            resolvedLanguage == listenerLanguage && utterance.target == null && detectedPartnerLanguage == null
        utterance.isFinal = utterance.isFinal || segment.isClosed
        if (nativeTarget != null && hasNativeTranslation) {
            utterance.translation = convertScript(Filler.strip(segment.translation, nativeTarget), nativeTarget)
            utterance.translatedSource = utterance.trimmedSource
            utterance.translatedLanguage = resolvedLanguage
            utterance.translatedTarget = nativeTarget
            utterance.isTranslationOnly = source.isBlank()
            utterance.translationState = if (segment.isSourceFinal) TranslationState.Current else TranslationState.Working
            if (utterance.hasContent) {
                speak(utterance, Filler.strip(segment.stableTranslation, nativeTarget), complete = false, completesTurn = false)
            }
        } else if (utterance.isSourceOnly) {
            utterance.translationState = TranslationState.Idle
        } else if (utterance.target == null || resolvedLanguage == null) {
            utterance.translationState = TranslationState.AwaitingPartner
        }

        if (!segment.isCatchUp && !invalidTarget && segment.isPartnerEvidence &&
            segment.languageIsFinal && segment.isSourceFinal &&
            language != null && language != listenerLanguage && utterance.trimmedSource.any { it.isLetter() }
        ) {
            val original = utterance.trimmedSource.trim { it.isPunctuation() }.lowercase()
            val translated = segment.translation.trim { it.isWhitespace() || it.isPunctuation() }.lowercase()
            // A passthrough name or ambiguous shared word is not enough to
            // choose the language for the listener's next reply.
            if ((translated.isEmpty() || original != translated) && automaticLanguageEvidence.add(utterance.id)) {
                if (language == detectedPartnerLanguage) {
                    pendingPartnerLanguage = null
                    pendingPartnerConfirmations = 0
                } else {
                    if (pendingPartnerLanguage == language) {
                        pendingPartnerConfirmations += 1
                    } else {
                        pendingPartnerLanguage = language
                        pendingPartnerConfirmations = 1
                    }
                    if (detectedPartnerLanguage == null || pendingPartnerConfirmations >= 2) {
                        detectedPartnerLanguage = language
                        pendingPartnerLanguage = null
                        pendingPartnerConfirmations = 0
                        bindPendingAutomaticTurns(language, before = utterance)
                    }
                }
            }
        }

        if (utterance.isAutomaticSourceFinal && !hasNativeTranslation) {
            if (resolvedLanguage == listenerLanguage && utterance.target == null) {
                utterance.wasAwaitingPartner = true
                utterance.suppressesAutomaticSpeech = true
                utterance.translationState = TranslationState.AwaitingPartner
            } else if (resolvedLanguage != null && utterance.target != null && utterance.needsTranslation &&
                (resolvedLanguage == listenerLanguage || nativeTarget == listenerLanguage)
            ) {
                if (utterance.wasAwaitingPartner && !utterance.isExplicitTranslationRequest) {
                    utterance.translationState = TranslationState.Idle
                } else {
                    utterance.isTyped = true
                    translate(utterance)
                }
            }
        }
        if (!segment.isClosed && !segment.isCatchUp) {
            current = utterance
            armSilenceFallback()
        } else if (current === utterance) {
            current = null
            silenceTimer?.cancel()
        }
        if (segment.isClosed && !segment.isSourceFinal) settleInterruptedAutomaticTurn(utterance)
    }

    /**
     * Bind only unresolved turns from this encounter. The most recent three
     * get visible backfill; none of these older questions plays automatically.
     */
    private fun bindPendingAutomaticTurns(language: Language, before: Utterance) {
        val preceding = utterances.takeWhile { it !== before }.map { it.id }.toSet()
        val pending = utterances.filter {
            it.isAutomatic && it.automaticSessionID == automaticSessionID &&
                it.sourceLanguage == listenerLanguage && it.target == null &&
                (it.id in preceding || it.isAutomaticSourceFinal)
        }
        for (utterance in pending) {
            utterance.bindAutomaticTarget(language)
            utterance.waitsForAutomaticPartner = false
            utterance.wasAwaitingPartner = true
            utterance.suppressesAutomaticSpeech = true
            utterance.translationState = TranslationState.Idle
        }
        for (utterance in pending.filter { it.isAutomaticSourceFinal }.takeLast(BACKFILLED_TURNS)) {
            utterance.isTyped = true
            translate(utterance)
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
        val existing = segmentUtterances[segment.id]
        val utterance = if (existing != null) {
            if (utterances.none { it === existing } || existing.isTyped) return
            existing
        } else {
            if (!segment.startsATurn) return
            finalizeCurrent()
            // Earlier segments' translations are complete once a new one starts.
            // Keep the last one: its translation can still arrive. Edited or
            // retried turns keep their IDs until the engine retires so late
            // native updates cannot recreate them. Catch-up IDs can skip.
            retireOlderSegments(segmentUtterances)
            Utterance(languages).also {
                utterances += it
                segmentUtterances[segment.id] = it
            }
        }

        show(segment, utterance)

        if (segment.isClosed) {
            if (current === utterance) finalizeCurrent() else utterance.isFinal = true
        } else if (!utterance.isFinal) {
            current = utterance
            armSilenceFallback()
        }
        if (utterance.hasContent) speak(utterance, segment.stableTranslation, complete = false, completesTurn = false)
    }

    /** Words, or a translation whose direction the provider has confirmed. */
    private val SpeechSegment.startsATurn: Boolean
        get() = source.isNotBlank() || (language?.let { it in languages } == true && translation.isNotBlank())

    private fun retireOlderSegments(segments: MutableMap<Int, Utterance>) {
        val last = segments.keys.maxOrNull()
        for ((id, older) in segments) {
            if (id != last && older.translationState == TranslationState.Working && !older.isTyped) {
                finishAbandonedTranslation(older)
            }
        }
        segments.entries.retainAll { it.key == last || it.value.isTyped }
    }

    /**
     * Shows a segment of speech from a dropout where the dropout happened,
     * ahead of whatever was said since.
     */
    private fun applyCatchUp(segment: SpeechSegment) {
        val existing = catchUpUtterances[segment.id]
        val utterance = if (existing != null) {
            if (utterances.none { it === existing } || existing.isTyped) return
            existing
        } else {
            if (!segment.startsATurn) return
            retireOlderSegments(catchUpUtterances)
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
        if (utterance.hasContent) speak(utterance, segment.stableTranslation, complete = false, completesTurn = false)
    }

    private fun show(segment: SpeechSegment, utterance: Utterance) {
        utterance.usesNativeTranslation = true
        // Detect first, so only Chinese text gets the chosen script; Japanese kanji must not.
        val source = segment.source.trimStart()
        val confirmed = segment.language?.takeIf { it in languages }
        val language = confirmed ?: LanguageDetector.detect(source, languages) ?: utterance.language
        val target = languages.other(language)
        if (utterance.hasContent && utterance.language != language) invalidateTranslation(utterance)
        utterance.setSource(convertScript(source, language), language)
        utterance.translation = convertScript(Filler.strip(segment.translation, target), target)
        utterance.isTranslationOnly = confirmed != null && utterance.source.isBlank() && utterance.translation.isNotBlank()
        utterance.translatedSource = if (utterance.translation.isEmpty()) null else utterance.trimmedSource
        utterance.translatedLanguage = if (utterance.translation.isEmpty()) null else utterance.language
        utterance.translationState =
            if (segment.isClosed && utterance.translation.isNotEmpty()) TranslationState.Current else TranslationState.Working
    }

    private fun convertScript(text: String, language: Language) =
        if (language == Language.CHINESE) settings.chineseScript.convert(text) else text

    private fun finishAbandonedTranslation(utterance: Utterance) {
        if (!utterance.hasContent) return
        if (utterance.isAutomatic && utterance.isAwaitingLanguage) {
            utterance.translationState = TranslationState.AwaitingPartner
            return
        }
        if (utterance.translation.isEmpty()) {
            utterance.translatedSource = null
            utterance.translatedLanguage = null
            utterance.translationState = TranslationState.Failed("Translation did not finish. Tap to retry.")
        } else {
            utterance.translationState = TranslationState.Current
        }
    }

    private fun failMissingSegmentTranslations() {
        val pending = segmentUtterances.values + catchUpUtterances.values +
            automaticSegmentUtterances.values + automaticCatchUpUtterances.values
        for (utterance in pending) {
            if (utterance.translationState == TranslationState.Working && !utterance.isTyped) finishAbandonedTranslation(utterance)
        }
    }

    /**
     * Segment identifiers belong to an engine instance. Keep its visible
     * history, but stop resolving a replacement engine's IDs to those turns.
     */
    private fun retireNativeSegments() {
        // A filler may already have fallen out of the bounded native maps.
        // Count hidden rows before finalization can remove an empty raw turn.
        val hidden = utterances.filter { !it.hasContent }
        dropoutIndex?.let { index ->
            val removedBefore = utterances.take(index).count { candidate -> hidden.any { it === candidate } }
            dropoutIndex = maxOf(0, index - removedBefore)
        }
        finalizeCurrent()
        failMissingSegmentTranslations()
        for (utterance in segmentUtterances.values + catchUpUtterances.values) utterance.isFinal = true
        for (utterance in automaticSegmentUtterances.values + automaticCatchUpUtterances.values) {
            utterance.isFinal = true
            if (utterance.translationState == TranslationState.Working && !utterance.isTyped) finishAbandonedTranslation(utterance)
            settleInterruptedAutomaticTurn(utterance)
        }
        for (utterance in hidden) {
            translations.remove(utterance.id)?.cancel()
            debounces.remove(utterance.id)?.cancel()
            speechFlushes.remove(utterance.id)?.cancel()
            spoken.remove(utterance.id)
        }
        utterances.removeAll { candidate -> hidden.any { it === candidate } }
        segmentUtterances.clear()
        catchUpUtterances.clear()
        automaticSegmentUtterances.clear()
        automaticCatchUpUtterances.clear()
    }

    /**
     * A local reset does not prove that the provider finished the words.
     * Keep them available for an explicit retry instead of automatically
     * speaking a partial line that may also arrive in a replay.
     */
    private fun settleInterruptedAutomaticTurn(utterance: Utterance) {
        if (!utterance.isAutomatic || utterance.isTyped || utterance.isAutomaticSourceFinal ||
            !utterance.hasContent || utterance.translation.isNotEmpty()
        ) {
            return
        }
        utterance.isFinal = true
        val source = utterance.sourceLanguage
        if (utterance.target == null && source != null) {
            if (source != utterance.listenerLanguage) {
                utterance.bindAutomaticTarget(utterance.listenerLanguage)
            } else {
                detectedPartnerLanguage?.let { utterance.bindAutomaticTarget(it) }
            }
        }
        utterance.waitsForAutomaticPartner =
            source == utterance.listenerLanguage && utterance.target == null && detectedPartnerLanguage == null
        utterance.translationState =
            if (utterance.target == null) TranslationState.AwaitingPartner else TranslationState.Failed(INTERRUPTED)
    }

    /**
     * Ends the turn if no text and no turn events have arrived for a while,
     * in case turn detection misses a boundary.
     */
    private fun armSilenceFallback() {
        silenceTimer?.cancel()
        silenceTimer = scope.launch {
            delay(if (isListening) 3_000 else 10_000)
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
            // An open native segment can still gain words after Stop.
            // Keep its hidden object attached until its final update arrives.
            val isOpenSegment = (segmentUtterances.values + automaticSegmentUtterances.values).any { it === utterance }
            if (!isOpenSegment) utterances.remove(utterance)
            return
        }
        if (utterance.needsTranslation) {
            debounces.remove(utterance.id)?.cancel()
            translate(utterance)
        } else if (translator != null && utterance.translationState == TranslationState.Current &&
            (!utterance.usesNativeTranslation || utterance.isTyped)
        ) {
            // Translated while it was spoken. A translating engine's turns
            // are read out as their segments arrive instead.
            speak(utterance, utterance.translation, complete = true)
        }
    }

    // endregion

    // region Translation

    /**
     * Cancel the old direction immediately, even if its request is stalled.
     * Other turns retain their queued speech and playback accounting.
     */
    private fun invalidateTranslation(utterance: Utterance) {
        translations.remove(utterance.id)?.cancel()
        debounces.remove(utterance.id)?.cancel()
        speechFlushes.remove(utterance.id)?.cancel()
        spoken.remove(utterance.id)
    }

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
        // A native segment's translation belongs to its speech provider,
        // which may still finish it on replay.
        if (utterance.usesNativeTranslation && !utterance.isTyped) return
        val text = utterance.trimmedSource
        if (utterance.isAutomatic && text.none { it.isLetterOrDigit() }) return
        if (text.isEmpty() || translations[utterance.id] != null) return
        val language = utterance.sourceLanguage ?: return
        val target = utterance.target ?: return
        if (utterance.isAutomatic && !(canUseAutomaticTurn(utterance) && utterance.isAutomaticSourceFinal)) return
        val translator = (if (utterance.isTyped) textTranslator else translator) ?: return
        if (utterance.isAutomatic && !isOnline) {
            utterance.translationState = TranslationState.WaitingForNetwork
            return
        }

        val context = utterances.takeWhile { it !== utterance }.filter {
            it.isFinal && it.hasContent && (!utterance.isAutomatic || (it.sourceLanguage == language && it.target == target))
        }.takeLast(3)
        val script = settings.chineseScript
        // The direction can be corrected while a request is running.
        fun isSameDirection() = utterance.sourceLanguage == language && utterance.target == target &&
            (!utterance.isAutomatic || canUseAutomaticTurn(utterance))

        utterance.translationState = TranslationState.Working
        translations[utterance.id] = scope.launch {
            var attempt = 0
            while (isActive) {
                if (utterance.isAutomatic) {
                    if (!isOnline) {
                        utterance.translationState = TranslationState.WaitingForNetwork
                        translations.remove(utterance.id)
                        return@launch
                    }
                } else if (!isOnline) {
                    // Hold the request until we're back online.
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
                        if (!isSameDirection()) throw DirectionChanged()
                        output += token
                        if (streamLive) utterance.translation = output
                    }
                    if (!isSameDirection()) throw DirectionChanged()
                    utterance.translation = output.trim()
                    utterance.translatedSource = text
                    utterance.translatedLanguage = language
                    utterance.translatedTarget = target
                    utterance.translationState =
                        if (utterance.needsTranslation) TranslationState.Working else TranslationState.Current
                    translations.remove(utterance.id)
                    if (utterance.isFinal && utterance.translationState == TranslationState.Current) {
                        speak(utterance, utterance.translation, complete = true)
                    }
                    // The speaker kept talking while we translated; catch up.
                    if (utterance.needsTranslation) translate(utterance)
                    return@launch
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (e is DirectionChanged || !isSameDirection()) {
                        translations.remove(utterance.id)
                        translate(utterance)
                        return@launch
                    }
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

    /** The turn's source or target was corrected under a running request. */
    private class DirectionChanged : Exception()

    // endregion

    // region Speech-to-speech

    /** Switches speech-to-speech mode, from the speaker button or Settings. */
    fun setSpeaksTranslations(on: Boolean) {
        settings.speaksTranslations = on
        speechSettingChanged()
    }

    /** Speech-to-speech mode is on. */
    val speaksTranslations: Boolean get() = settings.speaksTranslations

    /** True when a Soniox key is available for speech, from Settings or the broker. */
    val canSpeakTranslations: Boolean get() = SonioxSpeaker.credential(settings, keyProvider) != null

    /**
     * A language change applies immediately, including while Settings is open.
     * Old turns must not be spoken for a newly selected listener.
     */
    fun speechRoutingDidChange() {
        speaker?.stop()
        speaker = null
        speechFlushes.values.forEach { it.cancel() }
        speechFlushes.clear()
        spoken.clear()
        speakingSince = if (settings.speaksTranslations) System.currentTimeMillis() else null
    }

    private fun speechSettingChanged() {
        if (settings.speaksTranslations) {
            if (speakingSince == null) speakingSince = System.currentTimeMillis()
        } else {
            speakingSince = null
            speaker?.stop()
            speechFlushes.values.forEach { it.cancel() }
            speechFlushes.clear()
        }
    }

    /**
     * Reads a turn's translation aloud if it's for the other person: into
     * the second language of a pair, or away from the listener's language
     * in Automatic. A sentence at a time. [complete] includes an unpunctuated
     * tail. Native segments keep their character count after that flush
     * because more stable words may arrive; completed text translations seal
     * the turn with [completesTurn].
     *
     * iOS can also read the incoming direction into a headset; Android has
     * one audio output, so only the outgoing direction is spoken.
     */
    private fun speak(utterance: Utterance, stable: String, complete: Boolean, completesTurn: Boolean = true) {
        val since = speakingSince ?: return
        val target = utterance.target ?: return
        if (!settings.speaksTranslations || utterance.createdAt < since || utterance.suppressesAutomaticSpeech) return
        if (utterance.isAutomatic) {
            if (!canUseAutomaticTurn(utterance) || target !in Language.SONIOX || target == utterance.sourceLanguage) return
            if (target == utterance.listenerLanguage) return
        } else if (utterance.languages != settings.languages || target != languages.second) {
            return
        }
        val sent = spoken[utterance.id] ?: 0
        if (stable.length <= sent) return
        val fresh = stable.substring(sent)
        val ready = if (complete) fresh else completeSentences(fresh)
        if (ready.isNotEmpty()) {
            val speaker = activeSpeaker() ?: return
            speaker.speak(ready, target)
        }
        speechFlushes.remove(utterance.id)?.cancel()
        if (complete) {
            spoken[utterance.id] = if (completesTurn) Int.MAX_VALUE else sent + ready.length
        } else {
            spoken[utterance.id] = sent + ready.length
            // A last sentence without closing punctuation is read once the
            // turn has ended and its translation stops growing.
            if (ready.length == fresh.length || !utterance.isFinal) return
            speechFlushes[utterance.id] = scope.launch {
                delay(1_500)
                speechFlushes.remove(utterance.id)
                speak(utterance, stable, complete = true, completesTurn = completesTurn)
            }
        }
    }

    private fun canUseAutomaticTurn(utterance: Utterance) =
        isAutomaticLanguageMode && settings.usesAutomaticLanguageDetection &&
            utterance.listenerLanguage == settings.speechListenerLanguage &&
            utterances.any { it === utterance } &&
            (utterance.automaticSessionID == automaticSessionID || utterance.isExplicitTranslationRequest)

    private fun activeSpeaker(): SonioxSpeaker? {
        speaker?.let { return it }
        val credential = SonioxSpeaker.credential(settings, keyProvider) ?: return null
        return SonioxSpeaker(credential, host.makeSpeechPlayer(), scope).also {
            it.onError = { message ->
                setSpeaksTranslations(false)
                alert = message
            }
            speaker = it
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
        if (delayMs <= 0) {
            action()
            return
        }
        scope.launch {
            delay(delayMs)
            action()
        }
    }

    // endregion

    companion object {
        /** Only the first store in a launch prewarms. */
        private var didPrewarm = false

        /**
         * The text up to and including the last sentence end, or "" if none.
         * A period after a digit may be a decimal point, so it doesn't count
         * at the very end.
         */
        fun completeSentences(text: String): String {
            val enders = setOf('.', '!', '?', '。', '！', '？', '…', ';', '；', '؟', '।')
            var end = -1
            for (i in text.indices) {
                if (text[i] !in enders) continue
                val atEnd = i == text.lastIndex
                val followedBySpace = !atEnd && text[i + 1].isWhitespace()
                val wide = text[i].code > 0x7F
                val afterDigit = i > 0 && text[i - 1].isDigit()
                if (wide || followedBySpace || (atEnd && !afterDigit)) end = i + 1
            }
            return if (end < 0) "" else text.substring(0, end)
        }

        /**
         * How long a paused session stays open for a quick resume. Soniox bills
         * for the open stream, so this is kept short.
         */
        const val WARM_PAUSE_MS = 60_000L

        /** An Automatic conversation idle this long starts over with a new partner. */
        const val CONTEXT_EXPIRY_MS = 600_000L

        /** How many waiting turns are translated once the partner's language is known. */
        const val BACKFILLED_TURNS = 3

        private const val INTERRUPTED = "Translation interrupted. Tap to retry."
    }
}

/** As `CharacterSet.punctuationCharacters` on iOS: the Unicode P categories. */
private fun Char.isPunctuation() = when (Character.getType(this).toByte()) {
    Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
    Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
    Character.OTHER_PUNCTUATION,
    -> true
    else -> false
}
