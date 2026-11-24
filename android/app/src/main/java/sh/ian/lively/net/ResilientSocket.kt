package sh.ian.lively.net

import sh.ian.lively.R
import sh.ian.lively.support.modelString
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import sh.ian.lively.BuildConfig
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.support.DebugFlags
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt
import kotlin.random.Random

/** One WebSocket frame. */
sealed interface WsMessage {
    data class Text(val text: String) : WsMessage
    class Binary(val bytes: ByteArray) : WsMessage

    /** The frame decoded as a JSON object. */
    val jsonObject: JsonObject?
        get() {
            val text = when (this) {
                is Text -> text
                is Binary -> bytes.toString(Charsets.UTF_8)
            }
            return runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
        }

    companion object {
        /** Encodes a JSON object as a text frame. */
        fun json(element: JsonElement) = Text(element.toString())
    }
}

/**
 * The provider-specific half of a realtime speech WebSocket: how to open a
 * session, frame audio, and read the server's messages.
 */
interface SocketDialect {
    /**
     * Called before every connection. Throw [SocketSetupException] to stop;
     * any other error reconnects with backoff.
     */
    suspend fun makeRequest(stream: SocketStream): Request
    /** Sent first on every new connection, before any audio. */
    fun openingMessages(): List<WsMessage>
    fun audioMessage(chunk: ByteArray): WsMessage
    /** Sent on a clean stop while the session is up. */
    val endOfAudioMessage: WsMessage?
    /**
     * True when the server never acknowledges the session, so it's ready as
     * soon as the socket opens. Otherwise [receive] returns [SocketSignal.Ready].
     */
    val readyWhenOpen: Boolean
    /** Shown when the server rejects the API key. */
    val rejectedKeyMessage: String
    /**
     * The server rejected the key, during the handshake or in a message.
     * Return [SocketSignal.Fail] to stop, or [SocketSignal.Retry] to reconnect with a new request.
     */
    fun keyRejected(): SocketSignal = SocketSignal.Fail(rejectedKeyMessage)
    fun receive(message: WsMessage, stream: SocketStream): SocketSignal
    /** The live session was torn down after it had started. */
    fun sessionDidReset(stream: SocketStream)
    /** A connection is up and can take audio. */
    fun sessionDidOpen(stream: SocketStream) {}
    /** A connection failed before it was ready. */
    fun connectFailed(stream: SocketStream) {}

    /**
     * Keeps an idle session open while audio is paused. Null when the server
     * can't idle, so pausing stops instead.
     */
    val keepaliveMessage: WsMessage? get() = null
    /** Sent when audio pauses, so the server finishes what it has heard. */
    val pauseMessage: WsMessage? get() = null

    /**
     * Reconnect when audio has gone out but nothing has come back for this
     * many ms. Only for servers that reply steadily while audio flows.
     */
    val stallTimeoutMs: Long? get() = null
    /**
     * True when the server can take a second session at once, for catch-up
     * replay and make-before-break handover. The dialect then has to keep
     * separate state per stream.
     */
    val supportsSideStreams: Boolean get() = false
    /**
     * True while the stream is partway through an utterance, so a handover
     * should wait for [SocketSignal.Boundary].
     */
    fun isMidUtterance(stream: SocketStream): Boolean = false
    /** A catch-up or handed-over stream has closed; no more messages will come. */
    fun sideStreamDidEnd(stream: SocketStream) {}
    /**
     * True when the server says how much audio it has finalized, so audio
     * past that point can be sent again after the session drops.
     */
    val reportsFinalizedAudio: Boolean get() = false
    /** How much of the stream's audio the server has finalized so far, in seconds. */
    fun finalizedAudio(stream: SocketStream): Double = 0.0
}

/** Permanent: stop and report. */
class SocketSetupException(message: String) : Exception(message)

sealed interface SocketSignal {
    data object None : SocketSignal
    /** The session accepted its settings and can take audio. */
    data object Ready : SocketSignal
    /** An utterance just ended, so audio can move to another socket here. */
    data object Boundary : SocketSignal
    /**
     * Transient: reconnect with backoff. [throttled] backs off for longer,
     * for limits such as too many concurrent connections.
     */
    data class Retry(val reason: String, val throttled: Boolean = false) : SocketSignal
    /** Permanent: stop and report. */
    data class Fail(val message: String) : SocketSignal
}

/**
 * One server session. The live stream gets the microphone; a catch-up
 * stream replays speech that was held while the network was down.
 */
data class SocketStream(val id: Int, val isCatchUp: Boolean)

/**
 * A WebSocket that survives flaky networks, shared by all speech engines.
 * Confined to [scope]'s thread (the main thread in the app).
 *
 * - OkHttp keeps each socket's frames in order and pings every 4 s, which
 *   keeps NAT mappings alive and fails a dead socket. Dialects that reply
 *   steadily also get a stall watchdog, which finds a dead socket in
 *   `stallTimeoutMs` (2.5 s for Soniox).
 * - The socket is ready as soon as its handshake completes. An attempt that
 *   isn't up after [HEDGE_DELAY_MS] is raced by a second one, so a packet lost
 *   on a bad network doesn't hold up the connect.
 * - Reconnects use jittered exponential backoff, and retry at once when the
 *   network comes back.
 * - While the socket is down, audio is held in a bounded backlog. On
 *   reconnect, silence is cut out of it. A short remainder is sent ahead of
 *   live audio; a long one goes to a separate catch-up session, so live
 *   speech isn't stuck behind it (Soniox works through a burst at only about
 *   1.15× real time). Dialects without side streams replay the retained
 *   speech on the primary before new live audio.
 * - Soniox resumes the same stream across network changes and short transport losses.
 *   When no reconnect is offered, a second socket opens on the new network and
 *   audio moves to it at the next utterance boundary (make-before-break).
 * - Audio the server hasn't finalized is kept until it is. When a session
 *   drops, that audio goes back in the backlog and is sent again, so words
 *   that were in flight aren't lost.
 * - While paused, a live session is kept open with keepalives, so resuming
 *   doesn't reconnect. [prewarm] opens one that way before listening starts.
 */
class ResilientSocket(
    private val dialect: SocketDialect,
    private val scope: CoroutineScope,
    baseClient: OkHttpClient = sharedClient,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    var onStatus: (SpeechEngineStatus) -> Unit = {}

    var status: SpeechEngineStatus = SpeechEngineStatus.Idle
        private set(value) {
            if (field == value) return
            field = value
            debugLog("status $value")
            onStatus(value)
        }

    private val client = baseClient.newBuilder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .pingInterval(PING_INTERVAL_MS, TimeUnit.MILLISECONDS)
        .build()

    private var isRunning = false
    private var isPaused = false
    /**
     * A server that ends its session on pause must finish its old response
     * before fresh microphone audio can start a replacement session.
     */
    private var isResumingAfterDrain = false
    private var nextStreamID = 0

    /** The connection that gets live audio. */
    private var primary: Connection? = null
    /** A connection on a new network, waiting to take over. */
    private var standby: Connection? = null
    private var handoverTimer: Job? = null
    /** Old and catch-up connections finishing their work. */
    private val side = mutableListOf<Connection>()
    private var reconnectJob: Job? = null
    private var hedgeJob: Job? = null
    private var keepaliveJob: Job? = null
    /**
     * A stopped microphone may still have accepted audio waiting to connect,
     * or an end-of-audio response from a server that cannot stay warm.
     */
    private var pauseDrainJob: Job? = null

    private var failures = 0
    private var throttled = false
    private val backlog = ArrayDeque<ByteArray>()

    /**
     * Failed catch-up sessions retain their unfinished audio across a network
     * outage. The original deadline bounds both backoff and offline waiting.
     * [deadline] and [readyAt] are in [now] ms.
     */
    private class CatchUpRetry(
        val audio: List<ByteArray>,
        val deadline: Long,
        val readyAt: Long,
        val attempt: Int,
    )
    private val catchUpRetries = mutableListOf<CatchUpRetry>()
    private var catchUpRetryJob: Job? = null

    var networkAvailable = true
        set(value) {
            if (field == value) return
            field = value
            if (!value) {
                isResumingAfterDrain = false
                keepaliveJob?.cancel()
                keepaliveJob = null
                if (!isPaused) {
                    pauseDrainJob?.cancel()
                    pauseDrainJob = null
                }
                reconnectJob?.cancel()
                reconnectJob = null
                hedgeJob?.cancel()
                dropStandby()
                val live = primary
                if (live?.reconnect?.request != null) suspendStream(live)
                else tearDownPrimary(keepingAudio = true)
                side.toList().forEach(::closeSide)
                if (isRunning && isPaused) schedulePauseDrainDeadline()
                if (isRunning) status = SpeechEngineStatus.Reconnecting
            } else if (isRunning && !isPaused && (primary == null || status == SpeechEngineStatus.Reconnecting)) {
                val live = primary
                if (live != null && live.isSuspended) retryResume(live) else connect()
            }
            resumeCatchUpRetries()
        }

    /**
     * While set, every socket acts as if the network silently dropped its
     * packets, and new connections fail. For testing recovery.
     */
    private var blackholeUntil: Long? = null

    fun start() {
        isResumingAfterDrain = false
        endPause()
        isRunning = true
        failures = 0
        throttled = false
        backlog.clear()
        clearCatchUpRetries()
        connect()
        if (BuildConfig.DEBUG) scheduleSimulatedDropouts()
    }

    /**
     * Opens a session before anyone speaks, held like a pause, so the first
     * [resume] doesn't wait on the connect. Does nothing for a server that
     * can't idle.
     */
    fun prewarm() {
        if (isRunning || dialect.keepaliveMessage == null) return
        start()
        isPaused = true
        debugLog("prewarming")
    }

    fun stop() {
        isResumingAfterDrain = false
        endPause()
        isRunning = false
        hedgeJob?.cancel()
        primary?.let { p -> if (p.isReady) dialect.endOfAudioMessage?.let(p::send) }
        tearDownPrimary(keepingAudio = false)
        dropStandby()
        side.toList().forEach(::closeSide)
        clearCatchUpRetries()
        backlog.clear()
        status = SpeechEngineStatus.Idle
    }

    fun send(chunk: ByteArray) {
        if (!isRunning || isPaused) return
        val primary = primary
        if (primary != null && primary.isReady && !primary.isEnding) {
            enqueueAudio(chunk, primary)
        } else {
            backlog.addLast(chunk)
            trimBacklog()
        }
    }

    /** Move a resumable stream to the new network, or prepare a fresh standby. */
    fun networkPathChanged() {
        // A paused session finds out from its pings if the old network died.
        if (!isRunning || isPaused || !networkAvailable) return
        val primary = primary
        if (primary == null || !primary.isReady) {
            // Still connecting, maybe over the old network: start over on the new one.
            if (status == SpeechEngineStatus.Reconnecting || status == SpeechEngineStatus.Connecting) {
                failures = 0
                connect()
            }
            return
        }
        if (primary.reconnect?.request != null) {
            if (!primary.isSuspended) suspendStream(primary)
            return
        }
        if (!dialect.supportsSideStreams || standby != null) return
        val connection = makeConnection(isCatchUp = false)
        debugLog("network changed; opening stream ${connection.stream.id} on the new one")
        standby = connection
        open(connection)
    }

    /**
     * Stops taking audio but keeps the live session open, so [resume] is
     * instant. Accepted audio still waiting to connect is finalized once
     * ready; servers that cannot idle get a bounded window to finish it.
     */
    fun pause() {
        if (!isRunning || isPaused) return
        isPaused = true
        hedgeJob?.cancel()
        dropStandby()
        val primary = primary
        if (primary != null && primary.isReady && !primary.isEnding) {
            finishPausedAudio(primary)
            if (!networkAvailable) schedulePauseDrainDeadline()
        } else {
            schedulePauseDrainDeadline()
        }
    }

    private fun finishPausedAudio(primary: Connection) {
        flushBacklog(primary)
        primary.awaitingReplySince = null
        val keepalive = dialect.keepaliveMessage
        if (keepalive != null) {
            pauseDrainJob?.cancel()
            pauseDrainJob = null
            if (primary.hasSentAudio) dialect.pauseMessage?.let(primary::send)
            startKeepalive(primary, keepalive)
        } else {
            primary.isEnding = true
            dialect.endOfAudioMessage?.let(primary::send)
            schedulePauseDrainDeadline()
        }
    }

    private fun schedulePauseDrainDeadline() {
        if (pauseDrainJob != null) return
        pauseDrainJob = scope.launch {
            delay(DRAIN_DEADLINE_MS)
            if (isResumingAfterDrain) replaceDrainedSession()
            else if (isPaused) stop()
        }
    }

    private fun replaceDrainedSession() {
        isResumingAfterDrain = false
        pauseDrainJob?.cancel()
        pauseDrainJob = null
        // connect() closes the old turn before the replacement can emit text.
        // Fresh audio held during the drain remains in the backlog.
        connect()
    }

    private fun startKeepalive(primary: Connection, message: WsMessage) {
        keepaliveJob?.cancel()
        keepaliveJob = scope.launch {
            while (isActive) {
                delay(KEEPALIVE_INTERVAL_MS)
                if (primary.isClosed) return@launch
                if (primary.reconnect?.request == null) primary.send(message)
            }
        }
    }

    /** Takes audio again, on the paused session if it's still up. */
    fun resume() {
        val wasPaused = isPaused
        endPause()
        if (wasPaused && isRunning && primary?.isEnding == true) {
            isResumingAfterDrain = true
            schedulePauseDrainDeadline()
            status = SpeechEngineStatus.Connecting
            return
        }
        if (!wasPaused || !isRunning) {
            start()
            return
        }
        val primary = primary
        if (primary == null) {
            connect()
            return
        }
        // A prewarmed session still connecting: audio waits in the backlog.
        if (primary.isSuspended) {
            if (networkAvailable && primary.socket == null) retryResume(primary)
            return
        }
        if (!primary.isReady) return
        debugLog("resumed stream ${primary.stream.id}")
        status = SpeechEngineStatus.Live
    }

    private fun endPause() {
        isPaused = false
        pauseDrainJob?.cancel()
        pauseDrainJob = null
        keepaliveJob?.cancel()
        keepaliveJob = null
    }

    // region Connection

    /** One WebSocket and the jobs that serve it. */
    private inner class Connection(val stream: SocketStream) {
        var socket: WebSocket? = null
        var reconnect: SonioxReconnect? = null
        val isSuspended get() = reconnect?.deadline != null
        var sentBeforeDrop = 0
        var response: Response? = null
        val jobs = mutableListOf<Job>()
        var isReady = false
        var isClosed = false
        var hasSentAudio = false
        /** End-of-audio was sent; this connection can only return final text. */
        var isEnding = false
        /** When audio first went out after the last server message. */
        var awaitingReplySince: Long? = null
        /** Audio to send once ready, then end the stream (catch-up only). */
        var replay: List<ByteArray> = emptyList()
        /** When a catch-up stream stops trying, in [now] ms (catch-up only). */
        var deadline = 0L
        /** Earlier catch-up streams that failed with this replay. */
        var attempt = 0
        /**
         * Audio sent that the server hasn't finalized, oldest first, when
         * the dialect reports it.
         */
        val unconfirmed = ArrayDeque<ByteArray>()
        /** Where [unconfirmed] starts in the stream's audio, in seconds. */
        var unconfirmedStart = 0.0
        val createdAt = now()

        fun send(message: WsMessage) {
            reconnect?.record(message)
            if (!isSuspended) write(message)
        }

        fun write(message: WsMessage) {
            if (isBlackholed) return
            val socket = socket ?: return
            val queued = when (message) {
                is WsMessage.Text -> socket.send(message.text)
                is WsMessage.Binary -> socket.send(message.bytes.toByteString())
            }
            if (!queued) scope.launch {
                if (this@Connection.socket === socket) {
                    connectionFailed(this@Connection, SocketSignal.Retry(modelString(R.string.send_failed) { "Send failed" }))
                }
            }
        }

        fun close() {
            isClosed = true
            disconnect(normal = true)
        }

        fun disconnect(normal: Boolean) {
            jobs.forEach { it.cancel() }
            jobs.clear()
            if (!normal || socket?.close(1000, null) != true) socket?.cancel()
            socket = null
        }
    }

    private fun makeConnection(isCatchUp: Boolean): Connection {
        nextStreamID += 1
        return Connection(SocketStream(nextStreamID, isCatchUp))
    }

    private fun connect() {
        if (!isRunning) return
        if (!networkAvailable) {
            status = SpeechEngineStatus.Reconnecting
            return
        }
        reconnectJob?.cancel()
        reconnectJob = null
        tearDownPrimary(keepingAudio = true)
        status = if (failures == 0) SpeechEngineStatus.Connecting else SpeechEngineStatus.Reconnecting
        val connection = makeConnection(isCatchUp = false)
        primary = connection
        open(connection)
        scheduleHedge(connection)
    }

    /**
     * On a lossy network one attempt can sit for seconds on a lost packet.
     * If it isn't up after [HEDGE_DELAY_MS], a second attempt races it as the
     * standby, and whichever opens first carries the audio.
     */
    private fun scheduleHedge(connection: Connection) {
        hedgeJob?.cancel()
        if (!dialect.supportsSideStreams || throttled) return
        hedgeJob = scope.launch {
            delay(HEDGE_DELAY_MS)
            if (connection !== primary || connection.isReady || standby != null || !networkAvailable) return@launch
            debugLog("stream ${connection.stream.id} is slow to open; racing another")
            val hedge = makeConnection(isCatchUp = false)
            standby = hedge
            open(hedge)
        }
    }

    /** Fetches a request, then opens the socket and starts its jobs. */
    private fun open(connection: Connection) {
        connection.jobs += scope.launch {
            val request = try {
                if (isBlackholed) throw java.io.IOException("Simulated dropout")
                if (connection === primary && DebugFlags.slowConnectSeconds > 0 && BuildConfig.DEBUG) {
                    debugLog("simulated slow connect for ${DebugFlags.slowConnectSeconds} s")
                    delay((DebugFlags.slowConnectSeconds * 1000).toLong())
                }
                dialect.makeRequest(connection.stream)
            } catch (e: SocketSetupException) {
                if (!connection.isClosed) connectionFailed(connection, SocketSignal.Fail(e.message ?: modelString(R.string.couldnt_connect) { "Couldn't connect" }))
                return@launch
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!connection.isClosed) connectionFailed(connection, SocketSignal.Retry(modelString(R.string.couldnt_connect) { "Couldn't connect" }))
                return@launch
            }
            if (connection.isClosed) return@launch
            debugLog("stream ${connection.stream.id} has its request after ${now() - connection.createdAt} ms")
            start(connection, request)
        }
    }

    private fun start(connection: Connection, request: Request) {
        val resuming = connection.isSuspended
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                scope.launch {
                    if (connection.socket !== webSocket || resuming || connection.isReady || !dialect.readyWhenOpen) return@launch
                    debugLog("stream ${connection.stream.id} opened after ${now() - connection.createdAt} ms")
                    received(connection, SocketSignal.Ready)
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) = deliver(webSocket, WsMessage.Text(text))

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = deliver(webSocket, WsMessage.Binary(bytes.toByteArray()))

            private fun deliver(webSocket: WebSocket, message: WsMessage) {
                scope.launch {
                    if (connection.socket !== webSocket || isBlackholed) return@launch
                    if (handleReconnectMessage(connection, message)) return@launch
                    connection.awaitingReplySince = null
                    val signal = dialect.receive(message, connection.stream)
                    confirmAudio(connection)
                    received(connection, signal)
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                scope.launch {
                    if (connection.socket === webSocket) connectionFailed(connection, SocketSignal.Retry(modelString(R.string.closed_by_server_value, code) { "Closed by server ($code)" }))
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                scope.launch {
                    if (connection.socket !== webSocket) return@launch
                    connection.response = response
                    connectionFailed(connection, SocketSignal.Retry(t.message ?: modelString(R.string.connection_failed) { "Connection failed" }))
                }
            }
        }
        val socket = client.newWebSocket(request, listener)
        connection.socket = socket
        // OkHttp holds frames sent before the handshake and sends them once it's done.
        if (resuming) {
            connection.write(checkNotNull(connection.reconnect).handshake())
        } else {
            val opening = dialect.openingMessages()
            if ((opening.firstOrNull()?.jsonObject?.get("enable_reconnect") as? JsonPrimitive)?.booleanOrNull == true) {
                connection.reconnect = SonioxReconnect(request, MAX_BACKLOG)
            }
            opening.forEach(connection::write)
        }

        if (resuming || dialect.readyWhenOpen) {
            connection.jobs += scope.launch {
                delay(HANDSHAKE_TIMEOUT_MS)
                if (connection.socket === socket && (!connection.isReady || connection.isSuspended)) {
                    connectionFailed(connection, SocketSignal.Retry(modelString(R.string.handshake_timed_out) { "Handshake timed out" }))
                }
            }
        }

        dialect.stallTimeoutMs?.let { timeout ->
            connection.jobs += scope.launch {
                while (isActive) {
                    delay(250)
                    if (connection.isClosed) return@launch
                    val since = connection.awaitingReplySince
                    if (!connection.isSuspended && since != null && now() - since > timeout) {
                        connectionFailed(connection, SocketSignal.Retry(modelString(R.string.no_reply_from_the_server) { "No reply from the server" }))
                        return@launch
                    }
                }
            }
        }
    }

    // endregion

    // region Soniox stream reconnect

    private fun handleReconnectMessage(connection: Connection, message: WsMessage): Boolean {
        val state = connection.reconnect ?: return false
        val json = message.jsonObject ?: return false
        val type = (json["type"] as? JsonPrimitive)?.content
        if (connection.isSuspended) {
            val replay = if (type == "reconnected") state.acceptResume(json, connection.sentBeforeDrop) else null
            if (replay == null) {
                abandonResume(connection)
                return true
            }
            replay.forEach(connection::write)
            connection.awaitingReplySince = if (replay.isEmpty() || isPaused) null else now()
            startSonioxPings(connection)
            if (connection === primary) status = SpeechEngineStatus.Live
            return true
        }
        if (type == "reconnect") {
            if (state.acceptOffer(json)) {
                startSonioxPings(connection)
                if (!connection.isReady) received(connection, SocketSignal.Ready)
            } else {
                connection.reconnect = null
            }
            return true
        }
        if (type == "pong") {
            state.pong((json["id"] as? JsonPrimitive)?.intOrNull)
            return true
        }
        if ((json["error_type"] as? JsonPrimitive)?.content == "connection_replaced") {
            abandonResume(connection)
            return true
        }
        if (state.request == null) {
            // A server can accept the start request without offering reconnect.
            connection.reconnect = null
        } else {
            val seq = (json["seq"] as? JsonPrimitive)?.intOrNull ?: return false
            if (seq <= state.lastSequence) return true
            if (seq != state.lastSequence + 1) {
                suspendStream(connection)
                return true
            }
            state.lastSequence = seq
        }
        return false
    }

    private fun startSonioxPings(connection: Connection) {
        connection.jobs += scope.launch {
            while (isActive) {
                delay(5_000)
                val state = connection.reconnect ?: return@launch
                val ping = state.ping()
                if (ping == null) {
                    suspendStream(connection)
                    return@launch
                }
                connection.write(ping)
            }
        }
    }

    /** Keep the logical stream, parser and ordered outbox through a transport loss. */
    private fun suspendStream(connection: Connection) {
        val state = connection.reconnect ?: return
        val retrying = connection.isSuspended
        if (!retrying) {
            state.deadline = now() + 20_000
            connection.sentBeforeDrop = state.requestCount
        }
        connection.disconnect(normal = false)
        if (connection === primary) {
            hedgeJob?.cancel()
            dropStandby()
            status = SpeechEngineStatus.Reconnecting
        }
        if (!networkAvailable) return
        if (retrying) {
            connection.jobs += scope.launch {
                delay(300)
                retryResume(connection)
            }
        } else {
            retryResume(connection)
        }
    }

    private fun retryResume(connection: Connection) {
        if (connection.isClosed || !networkAvailable || connection.socket != null) return
        val state = connection.reconnect ?: return
        val deadline = state.deadline ?: return
        val request = state.request ?: return
        if (now() >= deadline) abandonResume(connection) else start(connection, request)
    }

    private fun abandonResume(connection: Connection) {
        connection.reconnect = null
        when (connection) {
            primary -> {
                tearDownPrimary(keepingAudio = true)
                handleFailure()
            }
            standby -> dropStandby()
            else -> closeSide(connection)
        }
    }

    // endregion

    // region Events

    private fun received(connection: Connection, signal: SocketSignal) {
        when {
            connection === primary -> handlePrimary(signal)
            connection === standby -> when (signal) {
                SocketSignal.Ready -> {
                    connection.isReady = true
                    dialect.sessionDidOpen(connection.stream)
                    standbyBecameReady()
                }
                is SocketSignal.Retry, is SocketSignal.Fail -> dropStandby()
                else -> {}
            }
            else -> when (signal) {
                SocketSignal.Ready -> {
                    connection.isReady = true
                    dialect.sessionDidOpen(connection.stream)
                    if (connection.stream.isCatchUp) sendReplay(connection)
                }
                // Includes the server finishing after end of audio.
                is SocketSignal.Retry, is SocketSignal.Fail -> closeSide(connection)
                else -> {}
            }
        }
    }

    private fun connectionFailed(connection: Connection, signal: SocketSignal) {
        if (signal is SocketSignal.Retry) debugLog("stream ${connection.stream.id} failed: ${signal.reason}")
        if (connection.reconnect?.request != null && signal is SocketSignal.Retry) {
            if (connection.isSuspended && connection.response?.code in 400..499) abandonResume(connection)
            else suspendStream(connection)
            return
        }
        if (!connection.isReady) dialect.connectFailed(connection.stream)
        when {
            connection === primary -> handlePrimary(signal)
            connection === standby -> dropStandby()
            else -> closeSide(connection)
        }
    }

    private fun handlePrimary(signal: SocketSignal) {
        val primary = primary ?: return
        when (signal) {
            SocketSignal.None -> {}
            SocketSignal.Ready -> {
                if (primary.isReady) return
                primary.isReady = true
                dialect.sessionDidOpen(primary.stream)
                // It won the race; a hedge still connecting isn't needed.
                hedgeJob?.cancel()
                dropStandby()
                primaryIsUp(primary)
            }
            SocketSignal.Boundary -> if (standby?.isReady == true) handOver()
            is SocketSignal.Retry -> {
                if (isResumingAfterDrain) {
                    replaceDrainedSession()
                    return
                }
                throttled = throttled || signal.throttled
                handleFailure()
            }
            is SocketSignal.Fail -> fail(signal.message)
        }
    }

    /**
     * The primary can take audio: send what was held, or hold a prewarmed
     * session open until audio comes.
     */
    private fun primaryIsUp(primary: Connection) {
        failures = 0
        throttled = false
        if (isPaused) {
            debugLog("stream ${primary.stream.id} is warm")
            finishPausedAudio(primary)
        } else {
            flushBacklog(primary)
        }
        status = SpeechEngineStatus.Live
    }

    private fun handleFailure() {
        if (!isRunning) return
        // A prewarm racing a slow attempt falls back to the other one.
        // (A paused session has no standby.)
        if (isPaused && standby != null) {
            promoteStandby()
            return
        }
        // Nobody is waiting on a paused session; reconnect when they come back.
        if (isPaused && (backlog.isEmpty() || !networkAvailable)) {
            debugLog("paused session dropped")
            stop()
            return
        }

        primary?.response?.code?.let { code ->
            if (code == 401 || code == 403) {
                val rejected = dialect.keyRejected()
                if (rejected is SocketSignal.Fail) {
                    fail(rejected.message)
                    return
                }
            }
            if (code == 429) throttled = true
        }

        // A socket already opening on a new network, or racing this one, takes over at once.
        if (standby != null) {
            promoteStandby()
            return
        }

        tearDownPrimary(keepingAudio = true)
        failures += 1
        status = SpeechEngineStatus.Reconnecting
        // 0.3 s, 0.6 s, 1.2 s… capped at 6 s, with jitter so clients don't
        // sync up. When the server says too many connections are open, start
        // at 5 s and go up to 30 s, so side sessions can't loop against the limit.
        val base = if (throttled) min(30.0, 5 * 2.0.pow(failures - 1)) else min(6.0, 0.3 * 2.0.pow(failures - 1))
        val delaySeconds = base * Random.nextDouble(0.8, 1.2)
        reconnectJob = scope.launch {
            delay((delaySeconds * 1000).toLong())
            if (networkAvailable) connect()
        }
    }

    private fun fail(message: String) {
        endPause()
        hedgeJob?.cancel()
        isRunning = false
        tearDownPrimary(keepingAudio = false)
        dropStandby()
        side.toList().forEach(::closeSide)
        clearCatchUpRetries()
        backlog.clear()
        status = SpeechEngineStatus.Failed(message)
    }

    /**
     * [keepingAudio] puts audio the server hadn't finalized back in the
     * backlog, ahead of what was held since, to send again on the next session.
     */
    private fun tearDownPrimary(keepingAudio: Boolean) {
        val primary = primary ?: return
        this.primary = null
        primary.close()
        if (keepingAudio && primary.unconfirmed.isNotEmpty()) {
            debugLog("stream ${primary.stream.id} dropped; keeping ${primary.unconfirmed.size} unfinalized chunks")
            backlog.addAll(0, primary.unconfirmed)
            trimBacklog()
        }
        primary.unconfirmed.clear()
        if (primary.isReady || primary.hasSentAudio) dialect.sessionDidReset(primary.stream)
    }

    // endregion

    // region Handover

    private fun standbyBecameReady() {
        val primary = primary
        if (primary == null || !primary.isReady) {
            // The primary is down or still connecting; the standby takes over now.
            promoteStandby()
            return
        }
        if (!dialect.isMidUtterance(primary.stream)) {
            handOver()
            return
        }
        handoverTimer = scope.launch {
            delay(HANDOVER_WAIT_MS)
            handOver()
        }
    }

    /** Makes the standby the primary in place of one that failed or never opened. */
    private fun promoteStandby() {
        val standby = standby ?: return
        this.standby = null
        handoverTimer?.cancel()
        hedgeJob?.cancel()
        tearDownPrimary(keepingAudio = true)
        primary = standby
        if (standby.isReady) {
            debugLog("stream ${standby.stream.id} took over")
            primaryIsUp(standby)
        } else {
            status = SpeechEngineStatus.Reconnecting
        }
    }

    /** Moves live audio to the standby and lets the old socket finish. */
    private fun handOver() {
        val standby = standby ?: return
        val old = primary ?: return
        if (!standby.isReady) return
        handoverTimer?.cancel()
        handoverTimer = null
        this.standby = null
        primary = standby
        side += old
        // The old session finishes what it has; nothing is sent again from it.
        old.unconfirmed.clear()
        debugLog("handed over from stream ${old.stream.id} to ${standby.stream.id}")
        dialect.endOfAudioMessage?.let(old::send)
        scope.launch {
            delay(DRAIN_DEADLINE_MS)
            if (!old.isClosed) closeSide(old)
        }
    }

    private fun dropStandby() {
        handoverTimer?.cancel()
        handoverTimer = null
        standby?.close()
        standby = null
    }

    private fun closeSide(connection: Connection) {
        side.remove(connection)
        if (connection.isClosed) return
        debugLog("closed side stream ${connection.stream.id}")
        connection.close()
        dialect.sideStreamDidEnd(connection.stream)
        retryCatchUp(connection)
    }

    /**
     * Retry unsent audio and the suffix the server has not finalized. A
     * successful send only queues bytes; it does not acknowledge recognition.
     */
    private fun retryCatchUp(failed: Connection) {
        if (!failed.stream.isCatchUp || !isRunning) return
        val replay = failed.unconfirmed + failed.replay
        failed.unconfirmed.clear()
        failed.replay = emptyList()
        if (replay.isEmpty()) return
        val delayMs = min(8_000L, 1_000L shl failed.attempt)
        if (now() + delayMs >= failed.deadline) {
            debugLog("catch-up stream ${failed.stream.id} gave up")
            return
        }
        catchUpRetries += CatchUpRetry(replay, failed.deadline, readyAt = now() + delayMs, attempt = failed.attempt + 1)
        resumeCatchUpRetries()
    }

    private fun clearCatchUpRetries() {
        catchUpRetryJob?.cancel()
        catchUpRetryJob = null
        catchUpRetries.clear()
    }

    private fun resumeCatchUpRetries() {
        catchUpRetryJob?.cancel()
        catchUpRetryJob = null
        if (!isRunning) return
        val time = now()
        catchUpRetries.removeAll { it.deadline <= time }
        if (networkAvailable) {
            val ready = catchUpRetries.filter { it.readyAt <= time }
            catchUpRetries.removeAll { it.readyAt <= time }
            ready.forEach { startCatchUp(it.audio, it.deadline, it.attempt) }
        }
        // Offline jobs remain owned until restoration or expiry; a backoff
        // timer firing without a network must not consume their only retry.
        val wake = catchUpRetries.minOfOrNull { if (networkAvailable) min(it.readyAt, it.deadline) else it.deadline }
            ?: return
        catchUpRetryJob = scope.launch {
            delay(wake - time)
            resumeCatchUpRetries()
        }
    }

    private fun startCatchUp(speech: List<ByteArray>, deadline: Long, attempt: Int) {
        if (!isRunning || !networkAvailable || now() >= deadline) return
        val catchUp = makeConnection(isCatchUp = true)
        catchUp.replay = speech
        catchUp.deadline = deadline
        catchUp.attempt = attempt
        debugLog("${speech.size} chunks of speech → catch-up stream ${catchUp.stream.id}")
        side += catchUp
        open(catchUp)
        scope.launch {
            delay(deadline - now())
            if (!catchUp.isClosed) closeSide(catchUp)
        }
    }

    // endregion

    // region Backlog

    private fun flushBacklog(connection: Connection) {
        val held = backlog.size
        val speech = trimSilence(backlog.toList())
        backlog.clear()
        val seconds = speech.size * MicCapture.CHUNK_DURATION

        if (seconds > CATCH_UP_THRESHOLD_S && dialect.supportsSideStreams) {
            debugLog("held $held chunks")
            startCatchUp(speech, now() + CATCH_UP_DEADLINE_MS, attempt = 0)
        } else {
            if (held > 0) debugLog("held $held chunks, replaying ${speech.size}")
            speech.forEach { enqueueAudio(it, connection) }
        }
    }

    private fun sendReplay(connection: Connection) {
        connection.replay.forEach { enqueueAudio(it, connection) }
        connection.replay = emptyList()
        dialect.endOfAudioMessage?.let(connection::send)
    }

    private fun enqueueAudio(chunk: ByteArray, connection: Connection) {
        connection.hasSentAudio = true
        if (connection.awaitingReplySince == null) connection.awaitingReplySince = now()
        if (dialect.reportsFinalizedAudio && (connection.stream.isCatchUp || connection === primary)) {
            connection.unconfirmed.addLast(chunk)
            while (connection.unconfirmed.size > MAX_BACKLOG) {
                connection.unconfirmedStart += duration(connection.unconfirmed.removeFirst())
            }
        }
        connection.send(dialect.audioMessage(chunk))
    }

    /** Lets go of audio the server has finalized. */
    private fun confirmAudio(connection: Connection) {
        if (!dialect.reportsFinalizedAudio || connection.unconfirmed.isEmpty()) return
        val finalized = dialect.finalizedAudio(connection.stream)
        while (connection.unconfirmed.isNotEmpty()) {
            val end = connection.unconfirmedStart + duration(connection.unconfirmed.first())
            // Half a millisecond of slack for rounding in the server's count.
            if (end > finalized + 0.0005) break
            connection.unconfirmedStart = end
            connection.unconfirmed.removeFirst()
        }
    }

    private fun trimBacklog() {
        while (backlog.size > MAX_BACKLOG) backlog.removeFirst()
    }

    // endregion

    // region Simulated dropouts

    private val isBlackholed: Boolean
        get() = blackholeUntil?.let { now() < it } ?: false

    private fun scheduleSimulatedDropouts() {
        DebugFlags.dropout?.let { (at, length) ->
            scope.launch {
                delay((at * 1000).toLong())
                if (!isRunning) return@launch
                debugLog("simulated dropout for $length s")
                blackholeUntil = now() + (length * 1000).toLong()
            }
        }
        if (DebugFlags.pathChangeAt > 0) {
            scope.launch {
                delay((DebugFlags.pathChangeAt * 1000).toLong())
                if (!isRunning) return@launch
                debugLog("simulated network change")
                networkPathChanged()
            }
        }
    }

    // endregion

    private fun debugLog(message: String) {
        if (BuildConfig.DEBUG) runCatching { Log.d("LivelySocket", message) }
    }

    companion object {
        /** About 60 s of audio at 80 ms per chunk. */
        const val MAX_BACKLOG = 750

        /** Length of a 16 kHz mono PCM16 chunk, in seconds. */
        fun duration(chunk: ByteArray): Double = (chunk.size / 2).toDouble() / MicCapture.SAMPLE_RATE
        /** Backlog speech beyond this goes to a catch-up session. */
        const val CATCH_UP_THRESHOLD_S = 3.0
        /** Catch-up translations later than this aren't worth showing. */
        const val CATCH_UP_DEADLINE_MS = 30_000L
        /** A handover waits at most this long for an utterance boundary. */
        const val HANDOVER_WAIT_MS = 8_000L
        /** An old socket gets this long to finish its last utterance. */
        const val DRAIN_DEADLINE_MS = 10_000L
        /**
         * A good connect takes about 0.5 s (Tools/probe/ASIA_LATENCY.md §2), and
         * one over a slow network a couple of seconds. Every attempt uses up a
         * broker key, so only a clearly stuck one gets raced.
         */
        const val HEDGE_DELAY_MS = 2_000L
        /** Soniox closes a session after 20 s without audio or a keepalive. */
        const val KEEPALIVE_INTERVAL_MS = 8_000L
        const val PING_INTERVAL_MS = 4_000L
        const val HANDSHAKE_TIMEOUT_MS = 5_000L

        val sharedClient: OkHttpClient by lazy { OkHttpClient() }

        /**
         * Cuts silence out of held audio with an energy gate. Speech keeps
         * 240 ms of padding on each side, and pauses inside speech are kept up
         * to 800 ms, so endpoint detection still splits utterances.
         */
        fun trimSilence(chunks: List<ByteArray>): List<ByteArray> {
            if (chunks.isEmpty()) return emptyList()
            val levels = chunks.map(::rms)
            // The quietest fifth of the backlog is taken as the noise floor.
            val floor = levels.sorted()[levels.size / 5]
            // About -45 dBFS at the least, so a silent backlog stays silent.
            val threshold = max(floor * 3, 0.0056f)
            val speech = levels.map { it > threshold }
            if (true !in speech) return emptyList()

            val pad = 3
            val maxPause = 10
            val keep = BooleanArray(chunks.size)
            for (i in speech.indices) if (speech[i]) {
                for (j in max(0, i - pad)..min(chunks.size - 1, i + pad)) keep[j] = true
            }
            // Padding already gives a pause 2 × pad chunks, so add up to the rest.
            val first = keep.indexOfFirst { it }
            val last = keep.indexOfLast { it }
            val result = mutableListOf<ByteArray>()
            var pause = 0
            for (i in first..last) {
                if (keep[i]) {
                    pause = 0
                    result += chunks[i]
                } else {
                    pause += 1
                    if (pause <= maxPause - 2 * pad) result += chunks[i]
                }
            }
            return result
        }

        /** Root mean square of a little-endian PCM16 chunk, 0…1. */
        fun rms(chunk: ByteArray): Float {
            val samples = chunk.size / 2
            if (samples == 0) return 0f
            var sum = 0.0
            for (i in 0 until samples) {
                val sample = ((chunk[2 * i + 1].toInt() shl 8) or (chunk[2 * i].toInt() and 0xFF)).toShort()
                val value = sample / 32767.0
                sum += value * value
            }
            return sqrt(sum / samples).toFloat()
        }
    }
}
