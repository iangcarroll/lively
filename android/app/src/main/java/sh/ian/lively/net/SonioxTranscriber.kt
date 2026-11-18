package sh.ian.lively.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair

/**
 * Streams microphone audio to Soniox `stt-rt-v5` with two-way translation:
 * one stream transcribes whichever language is spoken and translates it into
 * the other, so no separate [TranslationService] is needed.
 *
 * Protocol: https://soniox.com/docs/stt/rt/real-time-translation and
 * https://soniox.com/docs/stt/api-reference/websocket-api
 */
class SonioxTranscriber(
    private val config: Configuration,
    scope: CoroutineScope,
    client: OkHttpClient = ResilientSocket.sharedClient,
) : SpeechEngine, SocketDialect {
    sealed interface Credential {
        /** A long-lived key entered in Settings, for development. */
        data class ApiKey(val value: String) : Credential
        /** Temporary keys from Lively's key broker. */
        data class Broker(val provider: SonioxKeyProvider) : Credential
    }

    data class Configuration(
        val credential: Credential,
        val languages: LanguagePair,
        val model: String = "stt-rt-v5",
        /** How long Soniox waits before declaring an endpoint (500–3000 ms). */
        val maxEndpointDelayMs: Int = 1000,
    )

    override var onEvent: (SpeechEvent) -> Unit = {}
    override var onStatus: (SpeechEngineStatus) -> Unit
        get() = socket.onStatus
        set(value) { socket.onStatus = value }
    override var networkAvailable: Boolean
        get() = socket.networkAvailable
        set(value) { socket.networkAvailable = value }

    private val socket = ResilientSocket(this, scope, client)

    private data class SourcePiece(val text: String, val language: Language?)

    private data class PendingTranslation(val source: Language, val text: String)

    /**
     * Speech with one confirmed translation direction, within a provider turn.
     * Every property holds an immutable value, so [copy] is an independent
     * snapshot, like copying the Swift struct.
     */
    private data class Segment(
        val id: Int,
        var source: String = "",
        var translation: String = "",
        var language: Language? = null,
        var sourceLanguages: Set<Language> = emptySet(),
        var sourcePieces: List<SourcePiece> = emptyList(),
        /**
         * A different language can be an embedded name or a quick reply.
         * Only final translation metadata can confirm another direction.
         */
        var deferredSource: List<SourcePiece> = emptyList(),
        /**
         * A folded original is not receipted by a later chunk of the earlier
         * translation. Retain its provenance until directions are resolved.
         */
        var unreceiptedFoldStart: Int? = null,
        var hasAmbiguousSource: Boolean = false,
        var pendingTranslations: List<PendingTranslation> = emptyList(),
        var translationSource: Language? = null,
        var isClosed: Boolean = false,
        var lastShownLanguage: Language? = null,
        var hasProvisionalOverlay: Boolean = false,
    ) {
        /** [stableTranslation] is the final tokens' part, when non-final ones were added to [translation]. */
        fun event(isCatchUp: Boolean, stableTranslation: String? = null): SpeechSegment {
            val stable = if (translationSource == language) stableTranslation ?: translation else ""
            return SpeechSegment(id, source, translation, stable, language, isClosed, isCatchUp)
        }
    }

    /**
     * The segments of one server session. Sessions overlap during a
     * handover and while a catch-up session replays held speech.
     */
    private class StreamState(val isCatchUp: Boolean) {
        /** The segment receiving spoken words. Null after an endpoint until someone speaks again. */
        var open: Segment? = null
    }

    private var nextSegmentID = 0
    private val streams = mutableMapOf<Int, StreamState>()
    /**
     * Temporary keys rejected in a row. A temporary key that has expired is
     * rejected like a bad one, so a few rejections just mean "get a new key".
     */
    private var rejectedTemporaryKeys = 0
    /**
     * The region of each connection attempt, until it opens or fails.
     * Attempts overlap when a slow one is raced.
     */
    private val connectingRegions = mutableMapOf<Int, String>()
    /** Audio each stream's server has finalized, in seconds, from `final_audio_proc_ms`. */
    private val finalized = mutableMapOf<Int, Double>()

    override fun start() {
        rejectedTemporaryKeys = 0
        connectingRegions.clear()
        (config.credential as? Credential.Broker)?.provider?.startRefreshing()
        socket.start()
    }

    override fun prewarm() {
        rejectedTemporaryKeys = 0
        connectingRegions.clear()
        (config.credential as? Credential.Broker)?.provider?.startRefreshing()
        socket.prewarm()
    }

    /**
     * Finalizes what was heard and keeps the session open with keepalives.
     * The spare key keeps refreshing, in case the session drops meanwhile.
     */
    override fun pause() = socket.pause()

    override fun resume() = socket.resume()

    override fun send(chunk: ByteArray) = socket.send(chunk)

    override fun stop() {
        (config.credential as? Credential.Broker)?.provider?.stopRefreshing()
        socket.stop()
        for (id in streams.keys.toList()) closeOpenSegment(id)
        streams.clear()
        connectingRegions.clear()
        finalized.clear()
    }

    override fun endTurn() {
        // A local silence timeout can precede the service's final tokens.
        // Close the UI turn, but keep its ID until the provider's boundary.
        for (state in streams.values) {
            if (state.isCatchUp) continue
            val segment = state.open ?: continue
            segment.isClosed = true
            emitConfirmedOrRetract(segment, isCatchUp = false)
            segment.lastShownLanguage = segment.language ?: segment.lastShownLanguage
            segment.hasProvisionalOverlay = false
        }
    }

    override fun networkPathChanged() = socket.networkPathChanged()

    // region SocketDialect

    override suspend fun makeRequest(stream: SocketStream): Request {
        val (key, url) = when (val credential = config.credential) {
            is Credential.ApiKey -> credential.value to DEFAULT_ENDPOINT
            is Credential.Broker -> {
                val temporary = credential.provider.takeKey()
                connectingRegions[stream.id] = temporary.region
                temporary.value to temporary.websocketURL
            }
        }
        return Request.Builder().url(url).header("Authorization", "Bearer $key").build()
    }

    override fun sessionDidOpen(stream: SocketStream) {
        val provider = (config.credential as? Credential.Broker)?.provider ?: return
        val region = connectingRegions.remove(stream.id) ?: return
        provider.regions.connectSucceeded(region)
    }

    override fun connectFailed(stream: SocketStream) {
        val provider = (config.credential as? Credential.Broker)?.provider ?: return
        val region = connectingRegions.remove(stream.id) ?: return
        provider.regions.connectFailed(region)
    }

    override fun openingMessages() = listOf(
        WsMessage.json(
            buildJsonObject {
                put("model", config.model)
                put("audio_format", "pcm_s16le")
                put("sample_rate", MicCapture.SAMPLE_RATE)
                put("num_channels", 1)
                putJsonArray("language_hints") { config.languages.all.forEach { add(JsonPrimitive(it.code)) } }
                put("enable_language_identification", true)
                put("enable_endpoint_detection", true)
                put("max_endpoint_delay_ms", config.maxEndpointDelayMs)
                putJsonObject("translation") {
                    put("type", "two_way")
                    put("language_a", config.languages.first.code)
                    put("language_b", config.languages.second.code)
                }
            },
        ),
    )

    /** Raw PCM goes in binary frames. */
    override fun audioMessage(chunk: ByteArray) = WsMessage.Binary(chunk)

    /** An empty text frame ends the stream; an empty binary frame wouldn't. */
    override val endOfAudioMessage = WsMessage.Text("")

    /** Soniox only replies when it has tokens, so there's no session ack. */
    override val readyWhenOpen = true

    override val rejectedKeyMessage = "Your Soniox API key was rejected. Check it in Settings."

    /**
     * Soniox replies about every 0.12 s while audio flows, and within 1.1 s
     * at worst (Tools/probe/ASIA_LATENCY.md §2).
     */
    override val stallTimeoutMs = 2_500L

    /** https://soniox.com/docs/stt/rt/connection-keepalive */
    override val keepaliveMessage = WsMessage.json(buildJsonObject { put("type", "keepalive") })

    /** Finalizes pending tokens, so the last words before a pause show up now. */
    override val pauseMessage = WsMessage.json(buildJsonObject { put("type", "finalize") })

    override val supportsSideStreams = true

    /**
     * Every response carries `final_audio_proc_ms`, so audio Soniox hadn't
     * finalized when a session drops is sent again on the next one.
     */
    override val reportsFinalizedAudio = true

    override fun finalizedAudio(stream: SocketStream) = finalized[stream.id] ?: 0.0

    override fun isMidUtterance(stream: SocketStream) = streams[stream.id]?.open != null

    /**
     * Soniox rejects expired and reused temporary keys with 401, so a
     * rejected broker key means fetching a new one and reconnecting.
     */
    override fun keyRejected(): SocketSignal {
        if (config.credential !is Credential.Broker) return SocketSignal.Fail(rejectedKeyMessage)
        rejectedTemporaryKeys += 1
        if (rejectedTemporaryKeys >= 3) {
            return SocketSignal.Fail("Soniox is rejecting Lively's temporary keys. Try again in a few minutes.")
        }
        return SocketSignal.Retry("Temporary key rejected")
    }

    override fun sessionDidReset(stream: SocketStream) {
        // A new session starts a new segment; late tokens from the old one won't come.
        closeOpenSegment(stream.id)
        streams.remove(stream.id)
        finalized.remove(stream.id)
        onEvent(SpeechEvent.SessionReset)
    }

    override fun sideStreamDidEnd(stream: SocketStream) {
        closeOpenSegment(stream.id)
        streams.remove(stream.id)
        finalized.remove(stream.id)
    }

    override fun receive(message: WsMessage, stream: SocketStream): SocketSignal {
        val json = message.jsonObject ?: return SocketSignal.None

        json.int("error_code")?.let { code ->
            val text = json.string("error_message") ?: "Soniox error $code"
            return when (code) {
                401, 403 -> keyRejected()
                402 -> SocketSignal.Fail("Your Soniox balance or budget is used up.")
                400 -> SocketSignal.Fail("Soniox rejected the request: $text")
                // Too many sessions or requests: back off for longer.
                429 -> SocketSignal.Retry(text, throttled = true)
                // 408, 413 (session too long), 5xx: start a fresh session.
                else -> SocketSignal.Retry(text)
            }
        }

        // The key worked.
        rejectedTemporaryKeys = 0
        json.double("final_audio_proc_ms")?.let { finalized[stream.id] = it / 1000 }

        var endedUtterance = false
        val tokens = (json["tokens"] as? JsonArray)?.mapNotNull { it as? JsonObject }
        if (tokens != null && (tokens.isNotEmpty() || streams[stream.id]?.open != null)) {
            val state = streams.getOrPut(stream.id) { StreamState(stream.isCatchUp) }
            endedUtterance = apply(tokens, state)
        }

        // The server closes after `finished`; we only stop on purpose, so reconnect.
        if (json.bool("finished") == true) return SocketSignal.Retry("Session finished")
        return if (endedUtterance) SocketSignal.Boundary else SocketSignal.None
    }

    // endregion

    // region Tokens

    /**
     * Final tokens are sent once and kept. Non-final tokens are a guess at
     * what follows and are replaced by every response, so they're shown but
     * never stored. Returns true when an utterance ended.
     */
    private fun apply(tokens: List<JsonObject>, state: StreamState): Boolean {
        var touched = false
        var endedUtterance = false
        for (token in tokens.filter { it.bool("is_final") == true }) {
            val text = token.string("text") ?: continue
            if (text == "<end>" || text == "<fin>") {
                // Provider boundaries finalize the transcription and its
                // translation. Token language changes are not speaker IDs.
                closeOpenSegment(state, providerBoundary = true)
                touched = false
                endedUtterance = true
                continue
            }
            if (token.string("translation_status") == "translation") {
                var segment = state.open ?: continue
                if (segment.source.isEmpty()) continue
                val pendingSource = segment.pendingTranslations.lastOrNull()?.source
                val source = translationSource(token, fallback = pendingSource ?: segment.translationSource) ?: continue
                if (!meaningful(text) && source != pendingSource && source != segment.translationSource) continue
                if (segment.hasAmbiguousSource && segment.translationSource != null &&
                    (segment.pendingTranslations.isNotEmpty() || segment.translationSource != source)
                ) {
                    segment.pendingTranslations = if (pendingSource == source) {
                        val last = segment.pendingTranslations.last()
                        segment.pendingTranslations.dropLast(1) + last.copy(text = last.text + text)
                    } else {
                        segment.pendingTranslations + PendingTranslation(source, text)
                    }
                    touched = true
                    continue
                }
                val current = segment.translationSource
                if (current != null && current != source) {
                    val matchingDeferred = segment.deferredSource.any { it.language == source && meaningful(it.text) }
                    if (segment.unreceiptedFoldStart != null || !matchingDeferred) {
                        // A provider final can be certain even when caption
                        // ownership is not. Keep its actual directed output.
                        segment.hasAmbiguousSource = true
                        segment.pendingTranslations += PendingTranslation(source, text)
                        touched = true
                        continue
                    }
                    val reply = segment.deferredSource
                    segment.deferredSource = emptyList()
                    segment.isClosed = true
                    emitConfirmedOrRetract(segment, state.isCatchUp)
                    segment = Segment(nextSegmentID)
                    nextSegmentID += 1
                    reply.forEach { appendOwnedSource(it, segment) }
                }
                if (segment.translationSource == null) deferTrailingSource(segment, source)
                segment.translation += text
                segment.translationSource = source
                segment.language = source
                state.open = segment
                touched = true
            } else {
                openSegmentIfNeeded(state)
                state.open?.let { appendSource(sourcePiece(token, text), it) }
                touched = true
            }
        }

        // Provisional text is a replacement overlay, including embedded
        // foreign words. It never commits a speaker or a speech prefix.
        val provisional = tokens.filter { it.bool("is_final") != true }
        val pendingSource = provisional.filter { it.string("translation_status") != "translation" }.mapNotNull { token ->
            token.string("text")?.takeIf { it != "<end>" && it != "<fin>" }?.let { sourcePiece(token, it) }
        }
        if (pendingSource.isNotEmpty()) openSegmentIfNeeded(state)
        val open = state.open ?: return endedUtterance
        val segment = open.copy()
        val stable = segment.translation
        pendingSource.forEach { appendSource(it, segment) }
        var pendingTranslationSource: Language? = null
        for (token in provisional.filter { it.string("translation_status") == "translation" }) {
            if (segment.source.isEmpty() || segment.pendingTranslations.isNotEmpty()) continue
            val text = token.string("text")?.takeIf { it != "<end>" && it != "<fin>" } ?: continue
            val source = translationSource(token, fallback = pendingTranslationSource ?: segment.translationSource) ?: continue
            if (!meaningful(text) && source != pendingTranslationSource && source != segment.translationSource) continue
            if (segment.translationSource != null && segment.translationSource != source) continue
            if (pendingTranslationSource != null && pendingTranslationSource != source) continue
            segment.translation += text
            pendingTranslationSource = source
            touched = true
        }
        segment.language = segment.translationSource ?: pendingTranslationSource ?: sourceLanguage(segment.sourceLanguages)
        if (touched || pendingSource.isNotEmpty() || segment.hasProvisionalOverlay) {
            if (emit(segment, state.isCatchUp, stable)) {
                open.lastShownLanguage = segment.language
                open.hasProvisionalOverlay = pendingSource.isNotEmpty() || pendingTranslationSource != null
            } else {
                emitConfirmedOrRetract(open, state.isCatchUp)
                open.lastShownLanguage = open.language ?: open.lastShownLanguage
                open.hasProvisionalOverlay = false
            }
        }
        return endedUtterance
    }

    /**
     * Mixed token tags describe multilingual text, not a change of speaker.
     * Wait for translation metadata when they disagree about the sentence.
     */
    private fun sourceLanguage(languages: Set<Language>): Language? = languages.singleOrNull()

    private fun sourcePiece(token: JsonObject, text: String) =
        SourcePiece(text, if (meaningful(text)) configuredLanguage(token.string("language")) else null)

    private fun appendOwnedSource(piece: SourcePiece, segment: Segment) {
        segment.source += piece.text
        segment.sourcePieces += piece
        piece.language?.let { segment.sourceLanguages += it }
        segment.language = segment.translationSource ?: sourceLanguage(segment.sourceLanguages)
    }

    private fun appendSource(piece: SourcePiece, segment: Segment) {
        val current = segment.translationSource
        if (current != null) {
            if (segment.hasAmbiguousSource) {
                segment.deferredSource += piece
                return
            }
            if (piece.language == current) {
                // A source-language continuation folds an embedded name back
                // into an unfinished sentence. A completed reply can instead
                // precede another original source before translations catch up.
                if (segment.deferredSource.any { endsSentence(it.text) }) {
                    segment.deferredSource += piece
                    return
                }
                if (segment.deferredSource.isNotEmpty() && endsSentence(segment.source)) {
                    segment.hasAmbiguousSource = true
                    segment.deferredSource += piece
                    return
                }
                if (segment.deferredSource.isNotEmpty() && segment.unreceiptedFoldStart == null) {
                    segment.unreceiptedFoldStart = segment.sourcePieces.size
                }
                foldDeferredSource(segment)
            } else if (segment.deferredSource.isNotEmpty() || (piece.language != null && piece.language != current)) {
                segment.deferredSource += piece
                return
            }
        }
        appendOwnedSource(piece, segment)
    }

    private fun foldDeferredSource(segment: Segment) {
        val deferred = segment.deferredSource
        segment.deferredSource = emptyList()
        deferred.forEach { appendOwnedSource(it, segment) }
    }

    private fun setOwnedSource(pieces: List<SourcePiece>, segment: Segment) {
        segment.source = ""
        segment.sourcePieces = emptyList()
        segment.sourceLanguages = emptySet()
        pieces.forEach { appendOwnedSource(it, segment) }
    }

    private fun deferTrailingSource(segment: Segment, source: Language) {
        // The first translation may arrive after both sides have spoken.
        // Preserve an opposite-language suffix until its translation either
        // confirms a reply or the provider endpoint keeps it in this sentence.
        val pieces = segment.sourcePieces
        val last = pieces.indexOfLast { it.language == source }
        val candidates = pieces.indices.filter { pieces[it].language != null && pieces[it].language != source }
        val sentenceStart = candidates.firstOrNull { hasSentenceBoundary(it, pieces) }
        val firstOpposite = candidates.firstOrNull()
        val containsReturn = firstOpposite != null &&
            pieces.indices.any { it > firstOpposite && pieces[it].language == source }
        val ambiguous = containsReturn && last >= 0 && sentenceStart != firstOpposite
        val start = (if (ambiguous) firstOpposite else sentenceStart ?: candidates.firstOrNull { it > last }) ?: return
        val prefix = pieces.take(start)
        if (prefix.none { meaningful(it.text) }) return
        if (last < 0 && prefix.none { it.language == null && meaningful(it.text) }) return
        segment.hasAmbiguousSource = ambiguous
        segment.deferredSource = pieces.drop(start)
        setOwnedSource(prefix, segment)
    }

    private fun closeAmbiguousDirections(segment: Segment, isCatchUp: Boolean) {
        val firstSource = segment.translationSource ?: return
        val pieces = segment.sourcePieces + segment.deferredSource
        val directions = listOf(firstSource) + segment.pendingTranslations.map { it.source }
        if (pieces.size > 4096 || directions.size > 32) {
            emitUnassignedDirections(segment, isCatchUp)
            return
        }
        val candidatesByLanguage = mutableMapOf<Language, MutableList<Int>>()
        val meaningfulPrefix = mutableListOf(0)
        var precedingLanguage: Language? = null
        for (index in pieces.indices) {
            meaningfulPrefix += meaningfulPrefix[index] + if (meaningful(pieces[index].text)) 1 else 0
            val language = pieces[index].language ?: continue
            val boundary = hasSentenceBoundary(index, pieces)
            if (precedingLanguage != language || boundary) candidatesByLanguage.getOrPut(language) { mutableListOf() } += index
            precedingLanguage = language
        }
        if (candidatesByLanguage.values.sumOf { it.size } > 256) {
            emitUnassignedDirections(segment, isCatchUp)
            return
        }
        val cache = mutableMapOf<Pair<Int, Int>, List<List<Int>>>()
        fun match(direction: Int, previous: Int): List<List<Int>> {
            if (direction == directions.size) {
                val last = pieces.subList(previous, pieces.size).lastOrNull { it.language != null }?.language
                return if (last != null && last != directions[direction - 1]) emptyList() else listOf(emptyList())
            }
            val key = direction to previous
            cache[key]?.let { return it }
            val paths = mutableListOf<List<Int>>()
            for (start in candidatesByLanguage[directions[direction]].orEmpty().filter { it > previous }) {
                if (meaningfulPrefix[start] <= meaningfulPrefix[previous]) continue
                val last = pieces.subList(previous, start).lastOrNull { it.language != null }?.language
                if (last != null && last != directions[direction - 1]) continue
                val suffix = match(direction + 1, start)
                paths += suffix.take(2 - paths.size).map { listOf(start) + it }
                if (paths.size == 2) break
            }
            cache[key] = paths
            return paths
        }
        val matches = match(1, 0)
        if (matches.size != 1) {
            // Untimed translation tokens cannot identify equally plausible
            // source partitions. Preserve the original caption and emit the
            // provider's final translations without inventing source text.
            emitUnassignedDirections(segment, isCatchUp)
            return
        }
        val starts = listOf(0) + matches[0] + pieces.size
        for (index in directions.indices) {
            val resolved = if (index == 0) {
                segment.copy(deferredSource = emptyList(), pendingTranslations = emptyList(), hasAmbiguousSource = false)
            } else {
                Segment(nextSegmentID, translation = segment.pendingTranslations[index - 1].text).also { nextSegmentID += 1 }
            }
            setOwnedSource(pieces.subList(starts[index], starts[index + 1]), resolved)
            resolved.translationSource = directions[index]
            resolved.language = directions[index]
            resolved.isClosed = true
            emitConfirmedOrRetract(resolved, isCatchUp)
        }
    }

    private fun emitUnassignedDirections(segment: Segment, isCatchUp: Boolean) {
        val caption = segment.copy()
        foldDeferredSource(caption)
        caption.pendingTranslations = emptyList()
        caption.hasAmbiguousSource = false
        caption.isClosed = true
        emitConfirmedOrRetract(caption, isCatchUp)

        if (!meaningful(caption.source)) return
        for (translation in segment.pendingTranslations) {
            val translated = Segment(
                nextSegmentID,
                translation = translation.text,
                language = translation.source,
                translationSource = translation.source,
                isClosed = true,
            )
            nextSegmentID += 1
            emit(translated, isCatchUp)
        }
    }

    private fun hasSentenceBoundary(index: Int, pieces: List<SourcePiece>): Boolean {
        for (piece in pieces.subList(0, index).asReversed()) {
            if (endsSentence(piece.text)) return true
            if (meaningful(piece.text)) return false
        }
        return false
    }

    private fun endsSentence(text: String): Boolean {
        val closing = "\"'”’)]}"
        val last = text.lastOrNull { !it.isWhitespace() && it !in closing } ?: return false
        return last in ".?!。！？"
    }

    private fun translationSource(token: JsonObject, fallback: Language?): Language? {
        val sourceCode = token.string("source_language")
        val targetCode = token.string("language")
        val source = configuredLanguage(sourceCode)
        val target = configuredLanguage(targetCode)
        if (!sourceCode.isNullOrEmpty() && source == null) return null
        if (!targetCode.isNullOrEmpty() && target == null) return null
        if (source != null && target != null) return source.takeIf { it != target }
        if (source != null) return source
        if (target != null) return config.languages.other(target)
        // Missing metadata is useful only for formatting in an identified
        // translation; a new word must identify its source or target.
        return if (meaningful(token.string("text").orEmpty())) null else fallback
    }

    private fun configuredLanguage(code: String?): Language? {
        val base = code?.replace('_', '-')?.lowercase()?.split('-')?.firstOrNull { it.isNotEmpty() }
        return config.languages.language(base)
    }

    /**
     * True for text with a letter or a number in it. Code points stand in
     * for Swift's `Character.isLetter` and `isNumber`.
     */
    private fun meaningful(text: String): Boolean = text.codePoints().anyMatch {
        Character.isLetter(it) || when (Character.getType(it).toByte()) {
            Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
            else -> false
        }
    }

    private fun emit(segment: Segment, isCatchUp: Boolean, stableTranslation: String? = null): Boolean {
        // Wait for provider language evidence instead of letting an unknown
        // short transcript be guessed onto one of the conversation sides.
        if (segment.language == null) return false
        onEvent(SpeechEvent.Segment(segment.event(isCatchUp, stableTranslation)))
        return true
    }

    private fun emitConfirmedOrRetract(segment: Segment, isCatchUp: Boolean) {
        var confirmed = segment
        if (confirmed.language == null) {
            val language = confirmed.lastShownLanguage ?: return
            // A remembered preview direction can identify the view to clear,
            // but must not assign unclassified confirmed words to that side.
            confirmed = confirmed.copy(source = "", translation = "", translationSource = null, language = language)
        }
        emit(confirmed, isCatchUp)
    }

    private fun openSegmentIfNeeded(state: StreamState) {
        if (state.open != null) return
        state.open = Segment(nextSegmentID)
        nextSegmentID += 1
    }

    private fun closeOpenSegment(stream: Int) {
        val state = streams[stream] ?: return
        closeOpenSegment(state)
    }

    private fun closeOpenSegment(state: StreamState, providerBoundary: Boolean = false) {
        val segment = state.open ?: return
        state.open = null
        if (segment.pendingTranslations.isNotEmpty()) {
            if (providerBoundary) {
                closeAmbiguousDirections(segment, state.isCatchUp)
            } else {
                emitUnassignedDirections(segment, state.isCatchUp)
            }
            return
        }
        foldDeferredSource(segment)
        segment.isClosed = true
        emitConfirmedOrRetract(segment, state.isCatchUp)
    }

    // endregion

    companion object {
        /** The US region, for keys entered in Settings. Broker keys bring their own region's URL. */
        const val DEFAULT_ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"
    }
}

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
internal fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
internal fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
internal fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
internal fun JsonObject.obj(key: String): JsonObject? = runCatching { this[key]?.jsonObject }.getOrNull()
