package sh.ian.lively.net

import android.os.SystemClock
import android.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import sh.ian.lively.audio.SpeechPlayer
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.Language
import sh.ian.lively.model.SpeechProviders
import java.io.IOException

/**
 * Speaks translations aloud with Soniox real-time Text-to-Speech
 * (`tts-rt-v2`), for speech-to-speech mode.
 *
 * One WebSocket carries a stream per sentence. Sentences are generated one
 * at a time, in order, and their audio is queued in [SpeechPlayer], which
 * plays on while the next sentence is generated.
 *
 * Protocol: https://soniox.com/docs/translation/sts-translation and
 * https://soniox.com/docs/tts/rt/real-time-generation
 */
class SonioxSpeaker(
    private val credential: Credential,
    val player: SpeechPlayer,
    private val scope: CoroutineScope,
    private val client: OkHttpClient = ResilientSocket.sharedClient,
) {
    sealed interface Credential {
        /** A long-lived key entered in Settings, for development. */
        data class ApiKey(val value: String) : Credential
        /** Temporary Text-to-Speech keys from Lively's key broker. */
        data class Broker(val provider: SonioxKeyProvider) : Credential
    }

    /** A problem that stops speech for good, such as a rejected key. */
    var onError: (String) -> Unit = {}

    private data class Line(val text: String, val language: Language)

    private class FatalException(message: String) : Exception(message)
    /** Drop the connection and try the sentence again on a new one. */
    private class ReconnectException : Exception()

    /** One open connection and the messages it has received. */
    private class Connection(val socket: WebSocket, val messages: Channel<String>, val openedAt: Long)

    private val queue = ArrayDeque<Line>()
    private var worker: Job? = null
    private var connection: Connection? = null
    private var idleTimer: Job? = null
    private var nextStreamID = 0

    /** Queues a sentence to speak in [language]. */
    fun speak(text: String, language: Language) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        queue.addLast(Line(trimmed, language))
        idleTimer?.cancel()
        if (worker == null) worker = scope.launch { run() }
    }

    /** Stops speaking and drops everything queued. */
    fun stop() {
        queue.clear()
        worker?.cancel()
        worker = null
        idleTimer?.cancel()
        closeConnection()
        player.stop()
    }

    private suspend fun run() {
        while (queue.isNotEmpty() && scope.isActive) {
            val line = queue.removeFirst()
            for (attempt in 1..2) {
                try {
                    generate(line)
                    break
                } catch (e: CancellationException) {
                    throw e
                } catch (e: FatalException) {
                    queue.clear()
                    closeConnection()
                    onError(e.message ?: "Speech failed.")
                    break
                } catch (e: Exception) {
                    closeConnection()
                    // A sentence that fails twice is skipped, not retried forever.
                }
            }
        }
        worker = null
        idleTimer = scope.launch {
            delay(IDLE_CLOSE_MS)
            if (worker == null) closeConnection()
        }
    }

    /** Generates one sentence on its own stream and queues its audio. */
    private suspend fun generate(line: Line) {
        val connection = connected()
        val id = "lively-${nextStreamID++}"
        val config = buildJsonObject {
            put("stream_id", id)
            put("model", MODEL)
            put("language", line.language.code)
            put("voice", VOICE)
            put("audio_format", "pcm_s16le")
            put("sample_rate", SpeechPlayer.SAMPLE_RATE)
        }
        val text = buildJsonObject {
            put("stream_id", id)
            put("text", line.text)
            put("text_end", true)
        }
        if (!connection.socket.send(config.toString()) || !connection.socket.send(text.toString())) throw IOException("Socket closed")

        for (message in connection.messages) {
            val json = runCatching { Json.parseToJsonElement(message) as? JsonObject }.getOrNull() ?: continue
            val stream = json.string("stream_id")
            // Errors without a stream are about the connection.
            val code = json.int("error_code")
            if (code != null && (stream == null || stream == id)) {
                when (code) {
                    401, 403 -> {
                        // Temporary keys expire; a key from Settings won't get better.
                        if (credential !is Credential.Broker) {
                            throw FatalException("Your Soniox API key was rejected for speech. Check it in Settings.")
                        }
                        throw ReconnectException()
                    }
                    402 -> throw FatalException("Your Soniox balance or budget is used up.")
                    // This sentence failed; `terminated` follows on a live connection.
                    else -> if (stream == null) throw ReconnectException() else continue
                }
            }
            if (stream != id) continue
            json.string("audio")?.let { player.play(Base64.decode(it, Base64.DEFAULT)) }
            if ((json["terminated"] as? JsonPrimitive)?.booleanOrNull == true) return
        }
        // The channel closes when the socket does.
        throw IOException("Socket closed")
    }

    private suspend fun connected(): Connection {
        connection?.let {
            if (SystemClock.elapsedRealtime() - it.openedAt < CONNECTION_LIFETIME_MS && !it.messages.isClosedForReceive) return it
        }
        closeConnection()
        val (key, url) = when (credential) {
            is Credential.ApiKey -> credential.value to DEFAULT_ENDPOINT
            is Credential.Broker -> try {
                credential.provider.takeSpeechKey().let { it.value to it.websocketURL }
            } catch (e: SocketSetupException) {
                throw FatalException(e.message ?: "Lively's key service turned down the request.")
            }
        }
        val messages = Channel<String>(Channel.UNLIMITED)
        val request = Request.Builder().url(url).header("Authorization", "Bearer $key").build()
        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                messages.trySend(text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                messages.close()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                messages.close()
            }
        })
        return Connection(socket, messages, SystemClock.elapsedRealtime()).also { connection = it }
    }

    private fun closeConnection() {
        connection?.let {
            it.socket.close(1000, null)
            it.messages.close()
        }
        connection = null
    }

    companion object {
        const val MODEL = "tts-rt-v2"
        /** Soniox voices speak every language, so one voice serves every pair. */
        const val VOICE = "Adrian"

        /** The US region, for keys entered in Settings. Broker keys bring their own region's URL. */
        const val DEFAULT_ENDPOINT = "wss://tts-rt.soniox.com/tts-websocket"
        /** Temporary keys open new streams for 300 s; reconnect before that. */
        private const val CONNECTION_LIFETIME_MS = 240_000L
        /** Soniox closes a connection after 40 s without a message. */
        private const val IDLE_CLOSE_MS = 25_000L

        /** The credential speech would use, or null when there's no way to get a Soniox key. */
        fun credential(settings: AppSettings, keyProvider: SonioxKeyProvider?): Credential? {
            val key = settings.credential(SpeechProviders.sonioxCredential(keyProvider != null)).trim()
            if (key.isNotEmpty()) return Credential.ApiKey(key)
            return keyProvider?.let { Credential.Broker(it) }
        }
    }
}
