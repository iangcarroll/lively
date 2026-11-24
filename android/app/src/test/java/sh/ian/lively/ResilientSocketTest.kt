package sh.ian.lively

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import sh.ian.lively.net.ResilientSocket
import sh.ian.lively.net.SocketDialect
import sh.ian.lively.net.SocketSignal
import sh.ian.lively.net.SocketStream
import sh.ian.lively.net.SpeechEngineStatus
import sh.ian.lively.net.WsMessage
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * [ResilientSocket] against real WebSockets on a local MockWebServer, like
 * Tools/tests/SocketLifecycleRegression.swift and SocketReplayRegression.swift.
 * The socket's coroutines run on this thread under a virtual clock, so the
 * ten-second drain window and the catch-up backoff don't take real time;
 * only the network round trips do.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ResilientSocketTest {
    private val server = MockWebServer()
    private val scheduler = TestCoroutineScheduler()
    private val scope = CoroutineScope(StandardTestDispatcher(scheduler))
    /** Every WebSocket the server accepted, in order. */
    private val sessions = CopyOnWriteArrayList<Session>()
    /** Upcoming primary and catch-up connections to refuse with a 503. */
    private val refusedPrimaries = AtomicInteger()
    private val refusedCatchUps = AtomicInteger()
    private val sockets = mutableListOf<ResilientSocket>()

    /** The server's end of one WebSocket. Audio frames are logged by their marker. */
    private class Session(val path: String, val authorization: String?) : WebSocketListener() {
        val frames = CopyOnWriteArrayList<String>()
        @Volatile var socket: WebSocket? = null

        val isCatchUp get() = path.startsWith("/catchup")
        val audio get() = frames.mapNotNull { it.toIntOrNull() }

        fun send(event: String) = check(socket!!.send(event))
        fun close() = check(socket!!.close(1000, null))

        override fun onOpen(webSocket: WebSocket, response: Response) { socket = webSocket }
        override fun onMessage(webSocket: WebSocket, text: String) { frames += text.ifEmpty { EOF } }
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            frames += ((bytes[1].toInt() shl 8) or (bytes[0].toInt() and 0xFF)).toShort().toString()
        }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
    }

    private inner class Dialect(
        val keepsWarm: Boolean = true,
        val sides: Boolean = false,
        val tracksFinalized: Boolean = false,
        val nativeReconnect: Boolean = false,
    ) : SocketDialect {
        val requests = mutableListOf<SocketStream>()
        val opened = mutableListOf<SocketStream>()
        val responses = mutableListOf<Pair<SocketStream, String>>()
        val resets = mutableListOf<SocketStream>()
        val ended = mutableListOf<SocketStream>()
        /** Chunks the server says it finalized, by stream. */
        val finalized = mutableMapOf<Int, Int>()

        override suspend fun makeRequest(stream: SocketStream): Request {
            requests += stream
            return Request.Builder().url(server.url("/${if (stream.isCatchUp) "catchup" else "primary"}/${stream.id}"))
                .header("Authorization", "Bearer test-${requests.size}").build()
        }
        override fun openingMessages() = listOf(WsMessage.Text(if (nativeReconnect) """{"enable_reconnect":true}""" else "configure"))
        override fun audioMessage(chunk: ByteArray) = WsMessage.Binary(chunk)
        override val endOfAudioMessage = WsMessage.Text("")
        override val readyWhenOpen = false
        override val rejectedKeyMessage = "Unused loopback credential"
        override val keepaliveMessage get() = if (keepsWarm) WsMessage.Text("keepalive") else null
        override val pauseMessage = WsMessage.Text("finalize")
        override val supportsSideStreams get() = sides
        override val reportsFinalizedAudio get() = tracksFinalized
        override fun finalizedAudio(stream: SocketStream) = (finalized[stream.id] ?: 0) * 0.08
        override fun sessionDidReset(stream: SocketStream) { resets += stream }
        override fun sessionDidOpen(stream: SocketStream) { opened += stream }
        override fun sideStreamDidEnd(stream: SocketStream) { ended += stream }

        override fun receive(message: WsMessage, stream: SocketStream): SocketSignal {
            val event = (message as WsMessage.Text).text
            responses += stream to event
            return when {
                event == "ready" -> SocketSignal.Ready
                event == "finished" -> SocketSignal.Retry("Session finished")
                event == "fail" -> SocketSignal.Fail("Server refused")
                event.startsWith("finalized ") -> {
                    finalized[stream.id] = event.removePrefix("finalized ").toInt()
                    SocketSignal.None
                }
                else -> SocketSignal.None
            }
        }
    }

    @Before fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                val refused = if (path.startsWith("/catchup")) refusedCatchUps else refusedPrimaries
                if (refused.getAndUpdate { maxOf(0, it - 1) } > 0) return MockResponse.Builder().code(503).build()
                val session = Session(request.url.encodedPath + (request.url.encodedQuery?.let { "?$it" } ?: ""), request.headers["Authorization"])
                sessions += session
                return MockResponse.Builder().webSocketUpgrade(session).build()
            }
        }
        server.start()
    }

    @After fun tearDown() {
        sockets.forEach { it.stop() }
        scope.cancel()
        server.close()
    }

    private fun socket(dialect: Dialect) =
        ResilientSocket(dialect, scope, now = { scheduler.currentTime }).also { sockets += it }

    /** Runs the socket's coroutines until [condition] holds, while the network catches up. */
    private fun await(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000
        while (true) {
            scheduler.runCurrent()
            if (condition()) return
            if (System.nanoTime() > deadline) fail("Timed out waiting: $message")
            Thread.sleep(5)
        }
    }

    /** Gives anything that shouldn't happen the chance to. */
    private fun settle() {
        repeat(30) {
            scheduler.runCurrent()
            Thread.sleep(5)
        }
        scheduler.runCurrent()
    }

    /** Moves the socket's clock forward. */
    private fun advance(ms: Long) {
        scheduler.advanceTimeBy(ms)
        scheduler.runCurrent()
    }

    /** The [index]th accepted connection of a kind, once its WebSocket is open. */
    private fun session(index: Int, catchUp: Boolean = false): Session {
        fun matching() = sessions.filter { it.isCatchUp == catchUp && it.socket != null }
        await("${if (catchUp) "catch-up" else "primary"} session $index opens") { matching().size > index }
        return matching()[index]
    }

    private fun pcm(marker: Int) =
        ByteArray(2560) { i -> if (i % 2 == 0) (marker and 0xFF).toByte() else (marker shr 8).toByte() }

    /**
     * Quiet chunks establish the gate's floor. Distinct PCM amplitudes
     * identify the bytes the server received.
     */
    private fun bufferedSpeech(socket: ResilientSocket, first: Int = 4_000) {
        for (marker in listOf(0, 0, 0, 0, 0, first, first + 1_000, first + 2_000, 0, 0, 0, 0, 0)) socket.send(pcm(marker))
    }

    private fun speech(first: Int = 4_000) = listOf(0, 0, 0, first, first + 1_000, first + 2_000, 0, 0, 0)

    private fun live(dialect: Dialect): Pair<ResilientSocket, Session> {
        val socket = socket(dialect)
        socket.start()
        val session = session(0)
        session.send("ready")
        await("the first session is live") { socket.status == SpeechEngineStatus.Live }
        return socket to session
    }

    @Test fun reconnectRecoversAcrossTransportLossAndReplaysOnlyUnacceptedRequests() {
        val dialect = Dialect(sides = true, tracksFinalized = true, nativeReconnect = true)
        val socket = socket(dialect)
        socket.start()
        val first = session(0)
        val url = server.url("/resume?opaque=1").toString().replaceFirst("http:", "ws:")
        first.send("""{"type":"reconnect","reconnect_token":"first","reconnect_url":"$url"}""")
        await("stream ready") { socket.status == SpeechEngineStatus.Live }
        socket.send(pcm(1_000))
        await("first PCM") { first.audio == listOf(1_000) }
        val firstResult = """{"seq":1,"tokens":[]}"""
        first.send(firstResult)
        await("first result delivered") { dialect.responses.size == 1 }

        advance(5_000)
        val ping = """{"type":"ping","id":1}"""
        await("application ping numbers prior requests") { first.frames.last() == ping }
        first.send("""{"type":"pong","id":1}""")
        settle()
        socket.send(pcm(2_000))
        socket.networkAvailable = false
        socket.send(pcm(3_000))
        socket.pause()
        socket.resume()
        socket.send(pcm(4_000))
        socket.networkAvailable = true

        val attempt = session(1)
        val handshake = """{"type":"reconnect","reconnect_token":"first","last_seq":1}"""
        await("reconnect handshake goes first") { attempt.frames == listOf(handshake) }
        assertEquals("/resume?opaque=1", attempt.path)
        assertEquals(first.authorization, attempt.authorization)
        // The first attempt never answers. No audio, opening config or ping may pass.
        advance(5_000)
        advance(300)
        val resumed = session(2)
        await("unanswered attempt reuses token") { resumed.frames == listOf(handshake) }
        assertEquals(listOf(handshake), attempt.frames.toList())
        resumed.send("""{"type":"reconnected","reconnect_token":"rotated","last_request":1}""")
        await("replay includes the exact suffix and pause boundary") {
            resumed.frames == listOf(handshake, "2000", "3000", "finalize", "4000")
        }
        val missed = """{"seq":2,"tokens":[]}"""
        resumed.send(missed)
        resumed.send(missed)
        settle()
        assertEquals(listOf(firstResult, missed), dialect.responses.map { it.second })
        assertEquals(dialect.opened, dialect.responses.map { it.first }.distinct())
        assertTrue(dialect.resets.isEmpty())
        assertEquals(1, dialect.requests.size)

        // A silent connection fails when the second scheduled ping finds no pong.
        advance(5_000)
        await("ping counts requests across both connections") { resumed.frames.last() == """{"type":"ping","id":5}""" }
        advance(5_000)
        val refused = session(3)
        await("rotated token and latest sequence used") {
            refused.frames == listOf("""{"type":"reconnect","reconnect_token":"rotated","last_seq":2}""")
        }
        refused.send("""{"error_code":400,"error_type":"reconnect_failed"}""")
        await("old parser reset on refusal") { dialect.resets == dialect.opened }
        advance(400)
        val fresh = session(4)
        assertEquals("Bearer test-2", fresh.authorization)
        fresh.send("ready")
        await("ordinary stream ready after fallback") { socket.status == SpeechEngineStatus.Live }
    }

    // region Pause and resume

    @Test fun pauseBeforeReadyFinalizesAcceptedAudioAndResumeReusesTheSession() {
        val dialect = Dialect()
        val socket = socket(dialect)
        socket.start()
        bufferedSpeech(socket)
        socket.pause()
        socket.send(pcm(9_000))
        val session = session(0)
        session.send("ready")
        await("held speech is finalized") { session.frames.lastOrNull() == "finalize" }
        // Buffered PCM precedes finalize in order; paused PCM is absent.
        assertEquals(listOf("configure") + speech().map { it.toString() } + "finalize", session.frames.toList())
        assertEquals(SpeechEngineStatus.Live, socket.status)
        socket.send(pcm(9_000))
        settle()
        assertEquals(speech(), session.audio)

        socket.resume()
        socket.send(pcm(7_000))
        socket.pause()
        await("resumed speech is finalized") { session.frames.count { it == "finalize" } == 2 }
        assertEquals(speech() + 7_000, session.audio)
        assertEquals(1, dialect.requests.size)
        socket.stop()
        assertEquals(SpeechEngineStatus.Idle, socket.status)
    }

    @Test fun prewarmSendsNoAudioOrFinalizeAndStaysWarm() {
        val dialect = Dialect()
        val socket = socket(dialect)
        socket.prewarm()
        val session = session(0)
        session.send("ready")
        await("the prewarmed session opens") { dialect.opened.size == 1 }
        advance(ResilientSocket.KEEPALIVE_INTERVAL_MS)
        await("an idle session gets a keepalive") { session.frames.lastOrNull() == "keepalive" }
        assertEquals(listOf("configure", "keepalive"), session.frames.toList())
        socket.resume()
        socket.send(pcm(4_000))
        socket.pause()
        await("first speech is finalized on the prewarmed session") { session.frames.lastOrNull() == "finalize" }
        assertEquals(listOf(4_000), session.audio)
        assertEquals(1, dialect.requests.size)
    }

    @Test fun aServerThatCannotIdleFinishesItsReplyBeforeAReplacementSession() {
        val dialect = Dialect(keepsWarm = false)
        val (socket, first) = live(dialect)
        for (marker in listOf(0, 4_000, 0)) socket.send(pcm(marker))
        socket.pause()
        await("pause ends the audio") { first.frames.lastOrNull() == EOF }
        socket.send(pcm(9_000))
        socket.resume()
        assertEquals(SpeechEngineStatus.Connecting, socket.status)
        bufferedSpeech(socket, first = 7_000)
        settle()
        // New PCM waits for a new socket; it never follows the old end of audio.
        assertEquals(listOf(0, 4_000, 0), first.audio)
        assertEquals(1, dialect.requests.size)

        first.send("finished")
        val second = session(1)
        second.send("ready")
        await("held speech reaches the replacement") { second.audio.size == 9 }
        assertEquals(speech(7_000), second.audio)
        assertEquals(SpeechEngineStatus.Live, socket.status)
        assertEquals(2, dialect.requests.size)
    }

    @Test fun aSilentDrainIsReplacedAtItsDeadline() {
        val dialect = Dialect(keepsWarm = false)
        val (socket, first) = live(dialect)
        socket.send(pcm(4_000))
        socket.pause()
        socket.resume()
        bufferedSpeech(socket, first = 7_000)
        advance(ResilientSocket.DRAIN_DEADLINE_MS - 1)
        settle()
        assertEquals(1, dialect.requests.size)
        advance(1)
        val second = session(1)
        second.send("ready")
        await("held speech reaches the replacement") { second.audio.size == 9 }
        assertEquals(speech(7_000), second.audio)
        assertEquals(listOf(4_000), first.audio)
    }

    @Test fun aPausedServerThatCannotIdleStopsAfterItsDrainWindow() {
        val (socket, first) = live(Dialect(keepsWarm = false))
        socket.send(pcm(4_000))
        socket.pause()
        await("pause ends the audio") { first.frames.lastOrNull() == EOF }
        advance(ResilientSocket.DRAIN_DEADLINE_MS - 1)
        assertEquals(SpeechEngineStatus.Live, socket.status)
        advance(1)
        assertEquals(SpeechEngineStatus.Idle, socket.status)
    }

    @Test fun anUnreadyPausedSessionStopsWithinTheDrainWindow() {
        val dialect = Dialect()
        val socket = socket(dialect)
        socket.start()
        bufferedSpeech(socket)
        socket.pause()
        val session = session(0)
        // The server sees the connection open before the client has spoken;
        // the clock below must not run out ahead of the opening message.
        await("the session is configured") { session.frames.isNotEmpty() }
        advance(ResilientSocket.DRAIN_DEADLINE_MS - 1)
        // The timeout can't discard pending audio at once.
        assertEquals(SpeechEngineStatus.Connecting, socket.status)
        advance(1)
        assertEquals(SpeechEngineStatus.Idle, socket.status)
        settle()
        assertEquals(listOf("configure"), session.frames.toList())
        assertEquals(1, dialect.requests.size)
    }

    @Test fun aFailedPausedConnectionRetriesItsAcceptedAudio() {
        val dialect = Dialect()
        val socket = socket(dialect)
        val statuses = mutableListOf<SpeechEngineStatus>()
        socket.onStatus = { statuses += it }
        refusedPrimaries.set(1)
        socket.start()
        bufferedSpeech(socket)
        socket.pause()
        socket.send(pcm(9_000))
        await("the refused connection is retried") { socket.status == SpeechEngineStatus.Reconnecting }
        advance(1_000)
        val session = session(0)
        session.send("ready")
        await("held speech is finalized") { session.frames.lastOrNull() == "finalize" }
        assertEquals(speech(), session.audio)
        assertEquals(2, dialect.requests.size)
        assertTrue(SpeechEngineStatus.Reconnecting in statuses)
        assertEquals(SpeechEngineStatus.Live, socket.status)
    }

    // endregion

    // region Network loss

    @Test fun networkLossSuspendsTheSocketAndRestoreReplaysUnfinalizedAudioFirst() {
        val dialect = Dialect(tracksFinalized = true)
        val (socket, first) = live(dialect)
        for (marker in listOf(0, 4_000, 0)) socket.send(pcm(marker))
        await("the server has the unfinalized audio") { first.audio.size == 3 }
        socket.networkAvailable = false
        assertEquals(SpeechEngineStatus.Reconnecting, socket.status)
        for (marker in listOf(0, 5_000, 6_000, 0)) socket.send(pcm(marker))
        socket.networkPathChanged()
        advance(10_000)
        settle()
        assertEquals(1, dialect.requests.size)
        assertEquals(SpeechEngineStatus.Reconnecting, socket.status)

        socket.networkAvailable = true
        val second = session(1)
        second.send("ready")
        await("both intervals are replayed") { second.audio.size == 7 }
        assertEquals(listOf(0, 4_000, 0, 0, 5_000, 6_000, 0), second.audio)
        assertEquals(2, dialect.requests.size)
    }

    @Test fun aPausedSessionLostWithTheNetworkReconnectsOnlyOnResume() {
        val dialect = Dialect(tracksFinalized = true)
        val (socket, first) = live(dialect)
        for (marker in listOf(0, 7_000, 0)) socket.send(pcm(marker))
        socket.pause()
        await("pause finalizes") { first.frames.lastOrNull() == "finalize" }
        socket.networkAvailable = false
        socket.send(pcm(9_000))
        socket.networkAvailable = true
        settle()
        assertEquals(1, dialect.requests.size)

        socket.resume()
        val second = session(1)
        second.send("ready")
        await("accepted audio is replayed") { second.audio.size == 3 }
        // Old accepted bytes are kept; paused microphone input is not.
        assertEquals(listOf(0, 7_000, 0), second.audio)
    }

    @Test fun startingOfflineOnlyBuffersUntilTheNetworkReturns() {
        val dialect = Dialect()
        val socket = socket(dialect)
        socket.networkAvailable = false
        socket.start()
        assertEquals(SpeechEngineStatus.Reconnecting, socket.status)
        bufferedSpeech(socket)
        settle()
        assertTrue(dialect.requests.isEmpty())
        socket.networkAvailable = true
        val session = session(0)
        session.send("ready")
        await("held speech is sent") { session.audio.size == 9 }
        assertEquals(speech(), session.audio)
    }

    // endregion

    // region Replay

    @Test fun withoutSideStreamsAllRetainedSpeechIsReplayedBeforeNewAudio() {
        val dialect = Dialect()
        val socket = socket(dialect)
        socket.start()
        // Eight seconds: more than the five that used to be the limit.
        val markers = List(100) { if (it % 3 == 0) 0 else 4_000 + it }
        markers.forEach { socket.send(pcm(it)) }
        val session = session(0)
        session.send("ready")
        await("the whole backlog is replayed") { session.audio.size == 100 }
        socket.send(pcm(12_000))
        await("new audio follows") { session.audio.size == 101 }
        assertEquals(markers + 12_000, session.audio)
        assertTrue(dialect.requests.none { it.isCatchUp })
    }

    private val held = List(20) { 0 } + List(40) { 4_000 + it } + List(20) { 0 }
    private val heldSpeech = List(3) { 0 } + List(40) { 4_000 + it } + List(3) { 0 }

    /** A live primary whose held speech went to a catch-up stream. */
    private fun catchingUp(dialect: Dialect): ResilientSocket {
        val socket = socket(dialect)
        socket.start()
        held.forEach { socket.send(pcm(it)) }
        session(0).send("ready")
        await("held speech goes to a catch-up stream") { dialect.requests.any { it.isCatchUp } }
        return socket
    }

    @Test fun aCatchUpRetryStartsAfterTheFinalizedPrefix() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        catchingUp(dialect)
        val first = session(0, catchUp = true)
        first.send("ready")
        await("the replay is sent") { first.frames.lastOrNull() == EOF }
        assertEquals(heldSpeech, first.audio)
        first.send("finalized 20")
        first.close()
        await("the catch-up stream ends") { dialect.ended.size == 1 }
        advance(1_000)
        val retry = session(1, catchUp = true)
        retry.send("ready")
        await("the unfinalized suffix is sent again") { retry.frames.lastOrNull() == EOF }
        assertEquals(heldSpeech.drop(20), retry.audio)
        // Retained catch-up audio doesn't overtake fresh speech on the primary.
        assertTrue(session(0).audio.isEmpty())
    }

    @Test fun anUnsentCatchUpIsRetriedWhole() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        refusedCatchUps.set(1)
        catchingUp(dialect)
        await("the refused catch-up ends") { dialect.ended.size == 1 }
        advance(999)
        settle()
        assertEquals(1, dialect.requests.count { it.isCatchUp })
        advance(1)
        val retry = session(0, catchUp = true)
        retry.send("ready")
        await("the replay is sent") { retry.frames.lastOrNull() == EOF }
        assertEquals(heldSpeech, retry.audio)
    }

    @Test fun catchUpRetriesWaitForTheNetworkAndKeepTheirAudio() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        val socket = catchingUp(dialect)
        val first = session(0, catchUp = true)
        first.send("ready")
        await("the replay is sent") { first.frames.lastOrNull() == EOF }
        first.send("finalized 20")
        first.close()
        await("the catch-up stream ends") { dialect.ended.size == 1 }
        socket.networkAvailable = false
        advance(1_700)
        settle()
        // The backoff timer firing offline doesn't open a connection or use up the retry.
        assertEquals(1, dialect.requests.count { it.isCatchUp })
        socket.networkAvailable = true
        val retry = session(1, catchUp = true)
        retry.send("ready")
        await("the unfinalized suffix is sent again") { retry.frames.lastOrNull() == EOF }
        assertEquals(heldSpeech.drop(20), retry.audio)
    }

    @Test fun catchUpAudioExpiresAtItsOriginalDeadlineWhileOffline() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        val socket = catchingUp(dialect)
        val first = session(0, catchUp = true)
        first.send("ready")
        await("the replay is sent") { first.frames.lastOrNull() == EOF }
        first.close()
        await("the catch-up stream ends") { dialect.ended.size == 1 }
        socket.networkAvailable = false
        advance(ResilientSocket.CATCH_UP_DEADLINE_MS + 1_000)
        socket.networkAvailable = true
        session(1).send("ready")
        await("the primary reconnects") { socket.status == SpeechEngineStatus.Live }
        advance(10_000)
        settle()
        assertEquals(1, dialect.requests.count { it.isCatchUp })
    }

    @Test fun stopInvalidatesAQueuedCatchUpRetry() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        refusedCatchUps.set(1)
        val socket = catchingUp(dialect)
        await("the refused catch-up ends") { dialect.ended.size == 1 }
        socket.stop()
        socket.start()
        session(1).send("ready")
        await("the new session is live") { socket.status == SpeechEngineStatus.Live }
        advance(2_000)
        settle()
        assertEquals(1, dialect.requests.count { it.isCatchUp })
        assertTrue(session(1).audio.isEmpty())
    }

    @Test fun aPermanentFailureClosesSideStreamsAndTheirRetries() {
        val dialect = Dialect(sides = true, tracksFinalized = true)
        val socket = catchingUp(dialect)
        val catchUp = session(0, catchUp = true)
        session(0).send("fail")
        await("the socket fails") { socket.status == SpeechEngineStatus.Failed("Server refused") }
        assertEquals(listOf(true), dialect.ended.map { it.isCatchUp })
        advance(10_000)
        settle()
        assertEquals(1, dialect.requests.count { it.isCatchUp })
        assertTrue(catchUp.audio.isEmpty())
    }

    // endregion

    private companion object {
        /** How the server logs the empty text frame that ends the audio. */
        const val EOF = "<eof>"
    }
}
