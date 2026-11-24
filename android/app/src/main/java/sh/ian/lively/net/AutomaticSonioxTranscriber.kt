package sh.ian.lively.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Filler
import sh.ian.lively.model.Language

/**
 * Streams microphone audio to Soniox `stt-rt-v6` without naming the
 * languages: it identifies whichever language is spoken and translates it
 * one way, into the listener's. What the listener says is reported without
 * a translation, for the store to translate once it knows the other language.
 */
class AutomaticSonioxTranscriber(
    private val config: Configuration,
    scope: CoroutineScope,
    client: OkHttpClient = ResilientSocket.sharedClient,
) : SpeechEngine, SocketDialect {
    data class Configuration(
        val credential: SonioxTranscriber.Credential,
        val listenerLanguage: Language,
        val model: String = "stt-rt-v6",
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

    private var nextSegmentID = 0
    private val streams = mutableMapOf<Int, Epoch>()
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

    private val broker get() = (config.credential as? SonioxTranscriber.Credential.Broker)?.provider

    override fun start() {
        rejectedTemporaryKeys = 0
        connectingRegions.clear()
        broker?.startRefreshing()
        socket.start()
    }

    override fun prewarm() {
        rejectedTemporaryKeys = 0
        connectingRegions.clear()
        broker?.startRefreshing()
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
        broker?.stopRefreshing()
        socket.stop()
        for (id in streams.keys.toList()) closeOpenSegment(id)
        streams.clear()
        connectingRegions.clear()
        finalized.clear()
    }

    override fun endTurn() {
        for (epoch in streams.values.toList()) {
            if (epoch.isCatchUp) continue
            epoch.locallyClosed = true
            render(epoch, preview = emptyList(), closed = true, sourceFinal = false, evidence = false)
        }
    }

    override fun networkPathChanged() = socket.networkPathChanged()

    // region SocketDialect

    override suspend fun makeRequest(stream: SocketStream): Request {
        val (key, url) = when (val credential = config.credential) {
            is SonioxTranscriber.Credential.ApiKey -> credential.value to SonioxTranscriber.DEFAULT_ENDPOINT
            is SonioxTranscriber.Credential.Broker -> {
                val temporary = credential.provider.takeKey()
                connectingRegions[stream.id] = temporary.region
                temporary.value to temporary.websocketURL
            }
        }
        return Request.Builder().url(url).header("Authorization", "Bearer $key").build()
    }

    override fun sessionDidOpen(stream: SocketStream) {
        val region = connectingRegions.remove(stream.id) ?: return
        broker?.regions?.connectSucceeded(region)
    }

    override fun connectFailed(stream: SocketStream) {
        val region = connectingRegions.remove(stream.id) ?: return
        broker?.regions?.connectFailed(region)
    }

    override fun openingMessages() = listOf(
        WsMessage.json(
            buildJsonObject {
                put("model", config.model)
                put("enable_reconnect", true)
                put("audio_format", "pcm_s16le")
                put("sample_rate", MicCapture.SAMPLE_RATE)
                put("num_channels", 1)
                put("enable_language_identification", true)
                put("enable_endpoint_detection", true)
                put("max_endpoint_delay_ms", config.maxEndpointDelayMs)
                putJsonObject("translation") {
                    put("type", "one_way")
                    put("target_language", config.listenerLanguage.code)
                }
            },
        ),
    )

    /** Raw PCM goes in binary frames. */
    override fun audioMessage(chunk: ByteArray) = WsMessage.Binary(chunk)

    /** An empty text frame ends the stream; an empty binary frame wouldn't. */
    override val endOfAudioMessage = WsMessage.Text("")

    /** Audio can start at handshake, even when the server omits the reconnect offer. */
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

    override fun isMidUtterance(stream: SocketStream) = streams[stream.id]?.hasContent == true

    /**
     * Soniox rejects expired and reused temporary keys with 401, so a
     * rejected broker key means fetching a new one and reconnecting.
     */
    override fun keyRejected(): SocketSignal {
        if (broker == null) return SocketSignal.Fail(rejectedKeyMessage)
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
        if (tokens != null && (tokens.isNotEmpty() || streams[stream.id]?.hasContent == true)) {
            endedUtterance = apply(tokens, stream)
        }

        // The server closes after `finished`; we only stop on purpose, so reconnect.
        if (json.bool("finished") == true) return SocketSignal.Retry("Session finished")
        return if (endedUtterance) SocketSignal.Boundary else SocketSignal.None
    }

    // endregion

    // region Automatic source and translation lanes

    private enum class Kind { LISTENER, FOREIGN, UNKNOWN }

    private data class Piece(val text: String, val language: Language?, val kind: Kind)

    private class Group(val anchor: Int, val pieces: MutableList<Piece>, var kind: Kind) {
        val text: String get() = pieces.joinToString("") { it.text }
    }

    private class Native(
        val id: Int,
        val language: Language?,
        var explicitLanguage: Boolean,
        val sourceAnchor: Int?,
        var text: String,
    )

    /** What one server session has heard since its last endpoint. */
    private class Epoch(val isCatchUp: Boolean) {
        val source = mutableListOf<Piece>()
        val native = mutableListOf<Native>()
        var nativeLeading: Pair<Language?, String>? = null
        val sourceIDs = mutableMapOf<Int, Int>()
        var shown = mapOf<Int, AutoSpeechSegment>()
        var previewNativeID: Int? = null
        var locallyClosed = false
        val hasContent: Boolean get() = source.isNotEmpty() || native.isNotEmpty() || shown.isNotEmpty()
    }

    private fun allocateID() = nextSegmentID++

    private fun language(raw: String?): Language? {
        val code = raw?.replace('_', '-')?.lowercase()?.split('-')?.firstOrNull { it.isNotEmpty() } ?: return null
        return Language(code).takeIf { it in Language.SONIOX }
    }

    private fun meaningful(text: String) = text.codePoints().anyMatch { Character.isLetter(it) || isNumber(it) }

    /** As Swift's `Character.isNumber`: digits, letter numbers and other numbers. */
    private fun isNumber(codePoint: Int) = when (Character.getType(codePoint).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun isTranslation(token: JsonObject) = token.string("translation_status") == "translation"

    private fun isBoundary(text: String) = text == "<end>" || text == "<fin>"

    private fun piece(token: JsonObject, text: String): Piece {
        val lang = language(token.string("language"))
        val kind = when {
            lang != null -> if (lang == config.listenerLanguage) Kind.LISTENER else Kind.FOREIGN
            token.string("translation_status") == "original" -> Kind.FOREIGN
            else -> Kind.UNKNOWN
        }
        return Piece(text, lang, kind)
    }

    private fun groups(source: List<Piece>): MutableList<Group> {
        val result = mutableListOf<Group>()
        for ((index, piece) in source.withIndex()) {
            val last = result.lastOrNull()
            val languageBoundary = last != null && last.kind == Kind.FOREIGN && piece.kind == Kind.FOREIGN &&
                meaningful(piece.text) && endsSentence(last.text) &&
                piece.language != null && coherentLanguage(last) != null && piece.language != coherentLanguage(last)
            if (last != null && !languageBoundary &&
                (last.kind == piece.kind || piece.kind == Kind.UNKNOWN || last.kind == Kind.UNKNOWN)
            ) {
                if (last.kind == Kind.UNKNOWN) last.kind = piece.kind
                last.pieces += piece
            } else {
                result += Group(index, mutableListOf(piece), piece.kind)
            }
        }
        // A proper name can have a different word-level language tag without
        // indicating a new speaker. Fold it only when both surrounding source
        // lanes agree and neither earlier run has ended its sentence.
        var index = 1
        while (index + 1 < result.size) {
            val previous = result[index - 1]
            val middle = result[index]
            val following = result[index + 1]
            if (previous.kind == following.kind && !endsSentence(previous.text) && !endsSentence(middle.text)) {
                previous.pieces += middle.pieces + following.pieces
                result.subList(index, index + 2).clear()
                index = maxOf(1, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    private fun coherentLanguage(group: Group): Language? {
        val known = group.pieces
            .filter { meaningful(it.text) && (it.kind == group.kind || it.kind == Kind.UNKNOWN) }
            .mapNotNull { it.language }
            .toSet()
        return known.singleOrNull()
    }

    private fun sourceID(anchor: Int, epoch: Epoch) = epoch.sourceIDs.getOrPut(anchor) { allocateID() }

    private fun incomingLanguage(token: JsonObject, epoch: Epoch): Language? {
        if (token.containsKey("source_language")) return language(token.string("source_language"))
        val known = groups(epoch.source).filter { it.kind == Kind.FOREIGN }.mapNotNull(::coherentLanguage).toSet()
        return known.singleOrNull()
    }

    /** The native text a translation token continues, or the source it starts translating. */
    private class Placement(val existing: Native?, val anchor: Int?)

    private fun nativePlacement(source: Language?, epoch: Epoch, originals: List<Group>, isMeaningful: Boolean): Placement {
        val last = epoch.native.lastOrNull()
        if (last != null && last.language == source) {
            val index = last.sourceAnchor?.let { anchor -> originals.indexOfFirst { it.anchor == anchor } }?.takeIf { it >= 0 }
            val followedBySource = index != null && originals.drop(index + 1).any { meaningful(it.text) }
            if (!isMeaningful || !followedBySource || !nativeSentenceIsComplete(last.text)) return Placement(last, null)
        }
        val claimed = epoch.native.mapNotNull { it.sourceAnchor }.toSet()
        val candidates = originals.filter {
            it.kind == Kind.FOREIGN && source != null && coherentLanguage(it) == source && it.anchor !in claimed
        }
        return Placement(null, candidates.singleOrNull()?.anchor)
    }

    private fun appendNative(token: JsonObject, text: String, epoch: Epoch) {
        val rawTarget = token.string("language")
        val target = language(rawTarget)
        if (target != null && target != config.listenerLanguage) return
        if (!rawTarget.isNullOrEmpty() && target == null) return
        val explicit = language(token.string("source_language")) != null
        val source = if (!meaningful(text) && !token.containsKey("source_language")) {
            epoch.native.lastOrNull()?.language
        } else {
            incomingLanguage(token, epoch)
        }
        if (source == config.listenerLanguage) return
        val originals = groups(epoch.source)
        val placement = nativePlacement(source, epoch, originals, meaningful(text))
        placement.existing?.let { last ->
            last.text += text
            last.explicitLanguage = last.explicitLanguage || explicit
            return
        }
        if (epoch.source.none { meaningful(it.text) }) return
        val previous = epoch.nativeLeading
        if (!meaningful(text)) {
            val compatible = previous?.first == null || source == null || previous.first == source
            epoch.nativeLeading = source to (if (compatible) previous?.second.orEmpty() else "") + text
            return
        }
        val leading = previous?.takeIf { it.first == null || source == null || it.first == source }?.second.orEmpty()
        epoch.nativeLeading = null
        for (group in originals) sourceID(group.anchor, epoch)
        val anchor = placement.anchor
        val id = anchor?.let { sourceID(it, epoch) } ?: epoch.previewNativeID ?: allocateID()
        epoch.previewNativeID = null
        epoch.native += Native(id, source, explicit, anchor, leading + text)
    }

    /** Returns true when an utterance ended. */
    private fun apply(tokens: List<JsonObject>, stream: SocketStream): Boolean {
        var epoch = streams.getOrPut(stream.id) { Epoch(stream.isCatchUp) }
        val preview = mutableListOf<JsonObject>()
        var boundary = false
        for (token in tokens) {
            val text = token.string("text") ?: continue
            if (token.bool("is_final") != true) {
                preview += token
            } else if (isBoundary(text)) {
                render(epoch, preview = emptyList(), closed = true, sourceFinal = true, evidence = true)
                epoch = Epoch(epoch.isCatchUp)
                streams[stream.id] = epoch
                preview.clear()
                boundary = true
            } else if (isTranslation(token)) {
                appendNative(token, text, epoch)
            } else {
                epoch.source += piece(token, text)
            }
        }
        render(epoch, preview, closed = epoch.locallyClosed, sourceFinal = false, evidence = false)
        return boundary
    }

    private fun endsSentence(text: String): Boolean {
        val last = text.lastOrNull { !it.isWhitespace() && it !in "\"'”’)]}" } ?: return false
        return last in ".?!。！？"
    }

    private fun nativeSentenceIsComplete(text: String): Boolean {
        val trimmed = Filler.strip(text, config.listenerLanguage).trim()
        return trimmed.isNotEmpty() && ConversationStore.completeSentences(trimmed) == trimmed
    }

    private fun render(epoch: Epoch, preview: List<JsonObject>, closed: Boolean, sourceFinal: Boolean, evidence: Boolean) {
        val listener = config.listenerLanguage
        val volatile = preview.mapNotNull { token ->
            val text = token.string("text")
            if (isTranslation(token) || text == null || isBoundary(text)) null else piece(token, text)
        }
        val canonical = groups(epoch.source)
        val originals = groups(epoch.source + volatile)
        val desired = sortedMapOf<Int, AutoSpeechSegment>()
        for (group in originals) {
            val id = sourceID(group.anchor, epoch)
            val lang = coherentLanguage(group)
            val fixed = canonical.firstOrNull { it.anchor == group.anchor }
            val isWhole = group.pieces.size == fixed?.pieces?.size
            val corroborated = lang != null && epoch.native.any { it.language == lang && it.explicitLanguage }
            val finalLanguage = lang != null && fixed?.let(::coherentLanguage) == lang && isWhole
            val partnerEvidence = sourceFinal && evidence && !epoch.isCatchUp && finalLanguage &&
                group.kind == Kind.FOREIGN && corroborated
            val fallback = sourceFinal && evidence && group.kind == Kind.FOREIGN && lang != null && epoch.native.isEmpty()
            desired[id] = AutoSpeechSegment(
                id = id, source = group.text, language = lang, languageIsFinal = finalLanguage,
                target = if (fallback) listener else null, translation = "", stableTranslation = "",
                isClosed = closed, isSourceFinal = sourceFinal && isWhole,
                isCatchUp = epoch.isCatchUp, isPartnerEvidence = partnerEvidence,
            )
        }
        for (native in epoch.native) {
            val group = native.sourceAnchor?.let { anchor -> canonical.firstOrNull { it.anchor == anchor } }
            val finalLanguage = desired[native.id]?.languageIsFinal == true && native.language != null &&
                group?.let(::coherentLanguage) == native.language
            val segment = desired[native.id] ?: AutoSpeechSegment(
                id = native.id, source = "", language = native.language, languageIsFinal = false,
                target = listener, translation = "", stableTranslation = "",
                isClosed = closed, isSourceFinal = sourceFinal, isCatchUp = epoch.isCatchUp,
            )
            desired[native.id] = segment.copy(
                language = native.language,
                languageIsFinal = finalLanguage,
                isPartnerEvidence = sourceFinal && evidence && !epoch.isCatchUp && finalLanguage && native.explicitLanguage,
                target = listener,
                translation = native.text,
                stableTranslation = native.text,
            )
        }
        var previewID: Int? = null
        var previewLanguage: Language? = null
        for (token in preview) {
            if (!isTranslation(token)) continue
            val text = token.string("text") ?: continue
            if (isBoundary(text)) continue
            val rawTarget = token.string("language")
            if (!rawTarget.isNullOrEmpty() && language(rawTarget) != listener) continue
            val source = incomingLanguage(token, epoch)
            if (source == listener) continue
            if (previewID != null && previewLanguage != source) continue
            val id = previewID ?: run {
                val placement = nativePlacement(source, epoch, originals, meaningful(text))
                placement.existing?.id
                    ?: placement.anchor?.let { sourceID(it, epoch) }
                    ?: epoch.previewNativeID
                    ?: allocateID().also { epoch.previewNativeID = it }
            }
            previewID = id
            previewLanguage = source
            val segment = desired[id] ?: AutoSpeechSegment(
                id = id, source = "", language = source, languageIsFinal = false,
                target = listener, translation = "", stableTranslation = "",
                isClosed = closed, isSourceFinal = false, isCatchUp = epoch.isCatchUp,
            )
            desired[id] = segment.copy(
                target = listener,
                language = source,
                languageIsFinal = segment.languageIsFinal && segment.source.isNotEmpty(),
                isPartnerEvidence = false,
                translation = segment.translation + text,
            )
        }
        for ((id, previous) in epoch.shown) {
            if (id in desired) continue
            onEvent(
                SpeechEvent.AutoSegment(
                    previous.copy(
                        source = "", translation = "", stableTranslation = "", languageIsFinal = false,
                        isPartnerEvidence = false, isClosed = true, isSourceFinal = false,
                    ),
                ),
            )
        }
        for ((id, segment) in desired) {
            if (epoch.shown[id] != segment) onEvent(SpeechEvent.AutoSegment(segment))
        }
        epoch.shown = desired
    }

    private fun closeOpenSegment(stream: Int) {
        val epoch = streams[stream] ?: return
        render(epoch, preview = emptyList(), closed = true, sourceFinal = false, evidence = false)
    }

    // endregion
}
