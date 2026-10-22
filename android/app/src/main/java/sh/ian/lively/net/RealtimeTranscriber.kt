package sh.ian.lively.net

import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.model.AppSettings
import kotlin.math.max

/**
 * Streams microphone audio to Voxtral Mini Transcribe Realtime 3 and reports
 * transcript deltas and turn boundaries. Translation is left to a
 * [TranslationService].
 */
class RealtimeTranscriber(
    private val config: Configuration,
    scope: CoroutineScope,
    client: OkHttpClient = ResilientSocket.sharedClient,
) : SpeechEngine, SocketDialect {
    data class Configuration(
        val apiKey: String,
        val streamingDelayMs: Int,
        val model: String = AppSettings.TRANSCRIPTION_MODEL,
    )

    override var onEvent: (SpeechEvent) -> Unit = {}
    override var onStatus: (SpeechEngineStatus) -> Unit
        get() = socket.onStatus
        set(value) { socket.onStatus = value }
    override var networkAvailable: Boolean
        get() = socket.networkAvailable
        set(value) { socket.networkAvailable = value }

    /**
     * Turn events arrive as soon as the audio is heard, but transcript text
     * lags by the streaming delay. A boundary always follows at least
     * `min_silence_ms` (350 ms) of silence, so the previous turn's last words
     * arrive within (delay - 350 ms) of it. Waiting about that long keeps
     * trailing words in their turn without swallowing the next speaker's first.
     */
    override val textLagMs: Long get() = max(60, config.streamingDelayMs - 250).toLong()

    private val socket = ResilientSocket(this, scope, client)

    override fun start() = socket.start()
    override fun stop() = socket.stop()
    override fun send(chunk: ByteArray) = socket.send(chunk)

    // region SocketDialect

    override suspend fun makeRequest(stream: SocketStream): Request = Request.Builder()
        .url("$ENDPOINT?model=${config.model}")
        .header("Authorization", "Bearer ${config.apiKey}")
        .build()

    override fun openingMessages() = listOf(
        // Every setting must be in the first update: the session locks once audio arrives.
        WsMessage.json(
            buildJsonObject {
                put("type", "session.update")
                putJsonObject("session") {
                    putJsonObject("audio_format") {
                        put("encoding", "pcm_s16le")
                        put("sample_rate", MicCapture.SAMPLE_RATE)
                    }
                    put("target_streaming_delay_ms", config.streamingDelayMs)
                    // No "language": Voxtral detects it, so either person can speak at any time.
                    putJsonObject("turn_detection") {
                        put("start_threshold", 0.5)
                        put("eager_end_threshold", 0.4)
                        put("end_threshold", 0.33)
                        put("min_silence_ms", 350)
                        put("end_timeout_ms", 2000)
                    }
                }
            },
        ),
    )

    override fun audioMessage(chunk: ByteArray) = WsMessage.json(
        buildJsonObject {
            put("type", "input_audio.append")
            put("audio", Base64.encodeToString(chunk, Base64.NO_WRAP))
        },
    )

    override val endOfAudioMessage = WsMessage.json(buildJsonObject { put("type", "input_audio.end") })
    override val readyWhenOpen = false
    override val rejectedKeyMessage = "Your Mistral API key was rejected. Check it in Settings."

    override fun sessionDidReset(stream: SocketStream) = onEvent(SpeechEvent.SessionReset)

    override fun receive(message: WsMessage, stream: SocketStream): SocketSignal {
        val json = message.jsonObject ?: return SocketSignal.None
        when (json.string("type")) {
            "session.created", "session.updated" -> return SocketSignal.Ready
            "transcription.text.delta" -> json.string("text")?.takeIf { it.isNotEmpty() }?.let { onEvent(SpeechEvent.Text(it)) }
            "turn.start" -> onEvent(SpeechEvent.TurnStarted)
            "turn.eager_end" -> onEvent(SpeechEvent.TurnEagerEnded)
            "turn.resume" -> onEvent(SpeechEvent.TurnResumed)
            "turn.end" -> onEvent(SpeechEvent.TurnEnded)
            // The server finished this session (e.g. a duration limit). Start a fresh one.
            "transcription.done" -> return SocketSignal.Retry("Session ended")
            "error" -> {
                val error = json.obj("error")
                val text = error?.string("message") ?: "Transcription error"
                val code = (error?.get("code") as? JsonPrimitive)?.content.orEmpty()
                if (code.contains("401") || text.contains("api key", ignoreCase = true) ||
                    text.contains("unauthorized", ignoreCase = true)
                ) {
                    return SocketSignal.Fail(rejectedKeyMessage)
                }
                return SocketSignal.Retry(text)
            }
        }
        return SocketSignal.None
    }

    // endregion

    companion object {
        const val ENDPOINT = "wss://api.mistral.ai/v1/audio/transcriptions/realtime"
    }
}
