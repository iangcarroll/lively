package sh.ian.lively.net

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
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
 *   1.15× real time). Dialects without side streams replay at most 5 s.
 * - When the network changes, a second socket opens on the new network and
 *   audio moves to it at the next utterance boundary (make-before-break).
 * - While paused, a live session is kept open with keepalives, so resuming
 *   doesn't reconnect.
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

    private var failures = 0
    private var throttled = false
    private val backlog = ArrayDeque<ByteArray>()

    var networkAvailable = true
        set(value) {
            val old = field
            field = value
            if (value && !old && status == SpeechEngineStatus.Reconnecting) connect()
        }

    /**
     * While set, every socket acts as if the network silently dropped its
     * packets, and new connections fail. For testing recovery.
     */
    private var blackholeUntil: Long? = null

    fun start() {
        endPause()
        isRunning = true
        failures = 0
        throttled = false
        backlog.clear()
        connect()
        if (BuildConfig.DEBUG) scheduleSimulatedDropouts()
    }

    fun stop() {
        endPause()
        isRunning = false
        hedgeJob?.cancel()
        primary?.let { p -> if (p.isReady) dialect.endOfAudioMessage?.let(p::send) }
        tearDownPrimary()
        dropStandby()
        side.toList().forEach(::closeSide)
        backlog.clear()
        status = SpeechEngineStatus.Idle
    }

    fun send(chunk: ByteArray) {
        if (!isRunning || isPaused) return
        val primary = primary
        if (primary != null && primary.isReady) {
            enqueueAudio(chunk, primary)
        } else {
            backlog.addLast(chunk)
            while (backlog.size > MAX_BACKLOG) backlog.removeFirst()
        }
    }

    /**
     * The device moved to a different network. Opens a socket on the new
     * network before letting go of the old one.
     */
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
        if (!dialect.supportsSideStreams || standby != null) return
        val connection = makeConnection(isCatchUp = false)
        debugLog("network changed; opening stream ${connection.stream.id} on the new one")
        standby = connection
        open(connection)
    }

    /**
     * Stops taking audio but keeps the live session open, so [resume] is
     * instant. A session that isn't live yet, or a server that can't idle,
     * is stopped instead.
     */
    fun pause() {
        if (!isRunning || isPaused) return
        val primary = primary
        val keepalive = dialect.keepaliveMessage
        if (primary == null || !primary.isReady || keepalive == null) {
            stop()
            return
        }
        isPaused = true
        hedgeJob?.cancel()
        dropStandby()
        backlog.clear()
        primary.awaitingReplySince = null
        dialect.pauseMessage?.let(primary::send)
        debugLog("paused stream ${primary.stream.id}")
        keepaliveJob = scope.launch {
            while (isActive) {
                delay(KEEPALIVE_INTERVAL_MS)
                if (primary.isClosed) return@launch
                primary.send(keepalive)
            }
        }
    }

    /** Takes audio again, on the paused session if it's still up. */
    fun resume() {
        val wasPaused = isPaused
        endPause()
        val primary = primary
        if (!wasPaused || !isRunning || primary == null || !primary.isReady) {
            start()
            return
        }
        debugLog("resumed stream ${primary.stream.id}")
        status = SpeechEngineStatus.Live
    }

    private fun endPause() {
        isPaused = false
        keepaliveJob?.cancel()
        keepaliveJob = null
    }

    // region Connection

    /** One WebSocket and the jobs that serve it. */
    private inner class Connection(val stream: SocketStream) {
        var socket: WebSocket? = null
        var response: Response? = null
        val jobs = mutableListOf<Job>()
        var isReady = false
        var isClosed = false
        var hasSentAudio = false
        /** When audio first went out after the last server message. */
        var awaitingReplySince: Long? = null
        /** Audio to send once ready, then end the stream (catch-up only). */
        var replay: List<ByteArray> = emptyList()
        val createdAt = now()

        fun send(message: WsMessage) {
            if (isBlackholed) return
            val socket = socket ?: return
            when (message) {
                is WsMessage.Text -> socket.send(message.text)
                is WsMessage.Binary -> socket.send(message.bytes.toByteString())
            }
        }

        fun close() {
            isClosed = true
            jobs.forEach { it.cancel() }
            jobs.clear()
            socket?.close(1000, null)
            socket?.cancel()
            socket = null
        }
    }

    private fun makeConnection(isCatchUp: Boolean): Connection {
        nextStreamID += 1
        return Connection(SocketStream(nextStreamID, isCatchUp))
    }

    private fun connect() {
        if (!isRunning) return
        reconnectJob?.cancel()
        reconnectJob = null
        tearDownPrimary()
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
                if (!connection.isClosed) connectionFailed(connection, SocketSignal.Fail(e.message ?: "Couldn't connect"))
                return@launch
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!connection.isClosed) connectionFailed(connection, SocketSignal.Retry("Couldn't connect"))
                return@launch
            }
            if (connection.isClosed) return@launch
            debugLog("stream ${connection.stream.id} has its request after ${now() - connection.createdAt} ms")
            start(connection, request)
        }
    }

    private fun start(connection: Connection, request: Request) {
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                scope.launch {
                    if (connection.isClosed || !dialect.readyWhenOpen) return@launch
                    debugLog("stream ${connection.stream.id} opened after ${now() - connection.createdAt} ms")
                    received(connection, SocketSignal.Ready)
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) = deliver(WsMessage.Text(text))

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = deliver(WsMessage.Binary(bytes.toByteArray()))

            private fun deliver(message: WsMessage) {
                scope.launch {
                    if (connection.isClosed || isBlackholed) return@launch
                    connection.awaitingReplySince = null
                    received(connection, dialect.receive(message, connection.stream))
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                scope.launch {
                    if (!connection.isClosed) connectionFailed(connection, SocketSignal.Retry("Closed by server ($code)"))
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                scope.launch {
                    if (connection.isClosed) return@launch
                    connection.response = response
                    connectionFailed(connection, SocketSignal.Retry(t.message ?: "Connection failed"))
                }
            }
        }
        val socket = client.newWebSocket(request, listener)
        connection.socket = socket
        // OkHttp holds frames sent before the handshake and sends them once it's done.
        dialect.openingMessages().forEach(connection::send)

        if (dialect.readyWhenOpen) {
            connection.jobs += scope.launch {
                delay(HANDSHAKE_TIMEOUT_MS)
                if (!connection.isClosed && !connection.isReady) connectionFailed(connection, SocketSignal.Retry("Handshake timed out"))
            }
        }

        dialect.stallTimeoutMs?.let { timeout ->
            connection.jobs += scope.launch {
                while (isActive) {
                    delay(250)
                    if (connection.isClosed) return@launch
                    val since = connection.awaitingReplySince
                    if (since != null && now() - since > timeout) {
                        connectionFailed(connection, SocketSignal.Retry("No reply from the server"))
                        return@launch
                    }
                }
            }
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
                failures = 0
                throttled = false
                status = SpeechEngineStatus.Live
                dialect.sessionDidOpen(primary.stream)
                // It won the race; a hedge still connecting isn't needed.
                hedgeJob?.cancel()
                dropStandby()
                flushBacklog(primary)
            }
            SocketSignal.Boundary -> if (standby?.isReady == true) handOver()
            is SocketSignal.Retry -> {
                throttled = throttled || signal.throttled
                handleFailure()
            }
            is SocketSignal.Fail -> fail(signal.message)
        }
    }

    private fun handleFailure() {
        if (!isRunning) return
        // Nobody is waiting on a paused session; reconnect when they come back.
        if (isPaused) {
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

        tearDownPrimary()
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
        tearDownPrimary()
        dropStandby()
        isRunning = false
        backlog.clear()
        status = SpeechEngineStatus.Failed(message)
    }

    private fun tearDownPrimary() {
        val primary = primary ?: return
        this.primary = null
        primary.close()
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
        tearDownPrimary()
        primary = standby
        if (standby.isReady) {
            debugLog("stream ${standby.stream.id} took over")
            failures = 0
            throttled = false
            status = SpeechEngineStatus.Live
            flushBacklog(standby)
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
    }

    // endregion

    // region Backlog

    private fun flushBacklog(connection: Connection) {
        val held = backlog.size
        val speech = trimSilence(backlog.toList())
        backlog.clear()
        val seconds = speech.size * MicCapture.CHUNK_DURATION

        if (seconds > CATCH_UP_THRESHOLD_S && dialect.supportsSideStreams) {
            val catchUp = makeConnection(isCatchUp = true)
            catchUp.replay = speech
            debugLog("held $held chunks, ${speech.size} of speech → catch-up stream ${catchUp.stream.id}")
            side += catchUp
            open(catchUp)
            scope.launch {
                delay(CATCH_UP_DEADLINE_MS)
                if (!catchUp.isClosed) closeSide(catchUp)
            }
        } else {
            val limit = (MAX_REPLAY_S / MicCapture.CHUNK_DURATION).toInt()
            if (held > 0) debugLog("held $held chunks, replaying ${min(speech.size, limit)}")
            speech.takeLast(limit).forEach { enqueueAudio(it, connection) }
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
        connection.send(dialect.audioMessage(chunk))
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
        /** About 20 s of audio at 80 ms per chunk. */
        const val MAX_BACKLOG = 250
        /** Backlog speech beyond this goes to a catch-up session. */
        const val CATCH_UP_THRESHOLD_S = 3.0
        /** Without side streams, at most this much backlog speech is replayed. */
        const val MAX_REPLAY_S = 5.0
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
