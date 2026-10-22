package sh.ian.lively.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
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

    /** A run of speech between endpoints, with its translation. */
    private data class Segment(
        val id: Int,
        var source: String = "",
        var translation: String = "",
        var language: Language? = null,
        var isClosed: Boolean = false,
    ) {
        fun event(isCatchUp: Boolean) = SpeechSegment(id, source, translation, language, isClosed, isCatchUp)
    }

    /**
     * The segments of one server session. Sessions overlap during a
     * handover and while a catch-up session replays held speech.
     */
    private class StreamState(val isCatchUp: Boolean) {
        /** The segment receiving spoken words. Null after an endpoint until someone speaks again. */
        var open: Segment? = null
        /** The last closed segment. Its translation can still be arriving. */
        var previous: Segment? = null
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

    override fun start() {
        rejectedTemporaryKeys = 0
        connectingRegions.clear()
        (config.credential as? Credential.Broker)?.provider?.startRefreshing()
        socket.start()
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
    }

    override fun endTurn() {
        for ((id, state) in streams.toList()) if (!state.isCatchUp) closeOpenSegment(id)
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
        onEvent(SpeechEvent.SessionReset)
    }

    override fun sideStreamDidEnd(stream: SocketStream) {
        closeOpenSegment(stream.id)
        streams.remove(stream.id)
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

        var endedUtterance = false
        val tokens = (json["tokens"] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
        if (tokens.isNotEmpty()) {
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
        val touched = mutableSetOf<Int>()
        var endedUtterance = false

        for (token in tokens.filter { it.bool("is_final") == true }) {
            val text = token.string("text") ?: continue
            if (text == "<end>" || text == "<fin>") {
                val id = state.open?.id ?: continue
                // Report the segment this one replaces as `previous` before it's dropped.
                state.previous?.let { older -> if (touched.remove(older.id)) onEvent(SpeechEvent.Segment(older.event(state.isCatchUp))) }
                touched += id
                closeOpenSegment(state, notify = false)
                endedUtterance = true
                continue
            }
            if (token.string("translation_status") == "translation") {
                val source = config.languages.language(token.string("source_language"))
                if (translationTargetIsOpen(state, source, "")) {
                    state.open?.let { it.translation += text; touched += it.id }
                } else {
                    state.previous?.let { it.translation += text; touched += it.id }
                }
            } else {
                openSegmentIfNeeded(state)
                val open = state.open!!
                open.source += text
                config.languages.language(token.string("language"))?.let { open.language = it }
                touched += open.id
            }
        }

        // Overlay this response's non-final tokens on copies of the segments.
        var pendingSource = ""
        var pendingLanguage: Language? = null
        var pendingOpenTranslation = ""
        var pendingPreviousTranslation = ""
        for (token in tokens.filter { it.bool("is_final") != true }) {
            val text = token.string("text") ?: continue
            if (text == "<end>" || text == "<fin>") continue
            if (token.string("translation_status") == "translation") {
                val source = config.languages.language(token.string("source_language"))
                if (translationTargetIsOpen(state, source, pendingSource)) {
                    pendingOpenTranslation += text
                } else {
                    pendingPreviousTranslation += text
                }
            } else {
                pendingSource += text
                config.languages.language(token.string("language"))?.let { pendingLanguage = it }
            }
        }
        if (pendingSource.isNotEmpty()) openSegmentIfNeeded(state)
        if (pendingSource.isNotEmpty() || pendingOpenTranslation.isNotEmpty()) state.open?.let { touched += it.id }
        if (pendingPreviousTranslation.isNotEmpty()) state.previous?.let { touched += it.id }

        state.previous?.takeIf { it.id in touched }?.let { segment ->
            onEvent(SpeechEvent.Segment(segment.copy(translation = segment.translation + pendingPreviousTranslation).event(state.isCatchUp)))
        }
        state.open?.takeIf { it.id in touched }?.let { segment ->
            onEvent(
                SpeechEvent.Segment(
                    segment.copy(
                        source = segment.source + pendingSource,
                        translation = segment.translation + pendingOpenTranslation,
                        language = segment.language ?: pendingLanguage,
                    ).event(state.isCatchUp),
                ),
            )
        }
        return endedUtterance
    }

    /**
     * Translation follows the words it translates, so it belongs to the open
     * segment once that has words in the translation's source language, and
     * to the previous one until then.
     */
    private fun translationTargetIsOpen(state: StreamState, sourceLanguage: Language?, extraText: String): Boolean {
        val open = state.open ?: return false
        if ((open.source + extraText).isEmpty()) return false
        val language = open.language
        if (sourceLanguage == null || language == null) return true
        return sourceLanguage == language || state.previous == null
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

    private fun closeOpenSegment(state: StreamState, notify: Boolean = true) {
        val segment = state.open ?: return
        segment.isClosed = true
        state.open = null
        state.previous = segment
        if (notify) onEvent(SpeechEvent.Segment(segment.event(state.isCatchUp)))
    }

    // endregion

    companion object {
        /** The US region, for keys entered in Settings. Broker keys bring their own region's URL. */
        const val DEFAULT_ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"
    }
}

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
internal fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
internal fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
internal fun JsonObject.obj(key: String): JsonObject? = runCatching { this[key]?.jsonObject }.getOrNull()
