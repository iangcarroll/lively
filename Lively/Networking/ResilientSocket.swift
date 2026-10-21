import Foundation
import os

/// The provider-specific half of a realtime speech WebSocket: how to open a
/// session, frame audio, and read the server's messages.
protocol SocketDialect: AnyObject {
    /// Called before every connection. Throw `SocketSetupError.fail` to stop;
    /// any other error reconnects with backoff.
    func makeRequest() async throws -> URLRequest
    /// Sent first on every new connection, before any audio.
    func openingMessages() -> [URLSessionWebSocketTask.Message]
    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message
    /// Sent on a clean stop while the session is up.
    var endOfAudioMessage: URLSessionWebSocketTask.Message? { get }
    /// True when the server never acknowledges the session, so it's ready as
    /// soon as the socket opens. Otherwise `receive` returns `.ready`.
    var readyWhenOpen: Bool { get }
    /// Shown when the server rejects the API key.
    var rejectedKeyMessage: String { get }
    /// The server rejected the key, during the handshake or in a message.
    /// Return `.fail` to stop, or `.retry` to reconnect with a new request.
    func keyRejected() -> SocketSignal
    func receive(_ message: URLSessionWebSocketTask.Message, on stream: SocketStream) -> SocketSignal
    /// The live session was torn down after it had started.
    func sessionDidReset(_ stream: SocketStream)
    /// A connection is up and can take audio.
    func sessionDidOpen()

    /// Reconnect when audio has gone out but nothing has come back for this
    /// long. Only for servers that reply steadily while audio flows.
    var stallTimeout: Duration? { get }
    /// True when the server can take a second session at once, for catch-up
    /// replay and make-before-break handover. The dialect then has to keep
    /// separate state per stream.
    var supportsSideStreams: Bool { get }
    /// True while the stream is partway through an utterance, so a handover
    /// should wait for `.boundary`.
    func isMidUtterance(on stream: SocketStream) -> Bool
    /// A catch-up or handed-over stream has closed; no more messages will come.
    func sideStreamDidEnd(_ stream: SocketStream)
}

extension SocketDialect {
    func keyRejected() -> SocketSignal { .fail(rejectedKeyMessage) }
    func sessionDidOpen() {}
    var stallTimeout: Duration? { nil }
    var supportsSideStreams: Bool { false }
    func isMidUtterance(on stream: SocketStream) -> Bool { false }
    func sideStreamDidEnd(_ stream: SocketStream) {}
}

enum SocketSetupError: Error {
    /// Permanent: stop and report.
    case fail(String)
}

enum SocketSignal {
    case none
    /// The session accepted its settings and can take audio.
    case ready
    /// An utterance just ended, so audio can move to another socket here.
    case boundary
    /// Transient: reconnect with backoff. `throttled` backs off for longer,
    /// for limits such as too many concurrent connections.
    case retry(String, throttled: Bool = false)
    /// Permanent: stop and report.
    case fail(String)
}

/// One server session. The live stream gets the microphone; a catch-up
/// stream replays speech that was held while the network was down.
struct SocketStream: Hashable {
    let id: Int
    let isCatchUp: Bool
}

/// A WebSocket that survives flaky networks, shared by all speech engines.
///
/// - A single writer task per socket keeps messages in order.
/// - Pings every 4 s keep NAT mappings alive and find dead sockets. Dialects
///   that reply steadily also get a stall watchdog, which finds a dead socket
///   in `stallTimeout` (2.5 s for Soniox).
/// - Reconnects use jittered exponential backoff, and retry at once when the
///   network comes back.
/// - While the socket is down, audio is held in a bounded backlog. On
///   reconnect, silence is cut out of it. A short remainder is sent ahead of
///   live audio; a long one goes to a separate catch-up session, so live
///   speech isn't stuck behind it (Soniox works through a burst at only about
///   1.15× real time). Dialects without side streams replay at most 5 s.
/// - When the network path changes, a second socket opens on the new path and
///   audio moves to it at the next utterance boundary (make-before-break).
final class ResilientSocket {
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }

    private(set) var status: SpeechEngineStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            debugLog("status \(status)")
            onStatus(status)
        }
    }

    /// About 20 s of audio at 80 ms per chunk.
    private static let maxBacklog = 250
    /// Backlog speech beyond this goes to a catch-up session.
    private static let catchUpThreshold: TimeInterval = 3
    /// Without side streams, at most this much backlog speech is replayed.
    private static let maxReplay: TimeInterval = 5
    /// Catch-up translations later than this aren't worth showing.
    private static let catchUpDeadline: Duration = .seconds(30)
    /// A handover waits at most this long for an utterance boundary.
    private static let handoverWait: Duration = .seconds(8)
    /// An old socket gets this long to finish its last utterance.
    private static let drainDeadline: Duration = .seconds(10)

    private unowned let dialect: SocketDialect
    private var isRunning = false
    private let session = URLSession(configuration: .default)
    private var nextStreamID = 0

    /// The connection that gets live audio.
    private var primary: Connection?
    /// A connection on a new network path, waiting to take over.
    private var standby: Connection?
    private var handoverTimer: Task<Void, Never>?
    /// Old and catch-up connections finishing their work.
    private var side: [Connection] = []
    private var reconnectTask: Task<Void, Never>?

    private var failures = 0
    private var throttled = false
    private var backlog: [Data] = []
    var networkAvailable = true {
        didSet {
            if networkAvailable, !oldValue, status == .reconnecting { connect() }
        }
    }

    #if DEBUG
    /// While set, every socket acts as if the network silently dropped its
    /// packets, and new connections fail. For testing recovery.
    private var blackholeUntil: ContinuousClock.Instant?
    #endif

    init(dialect: SocketDialect) {
        self.dialect = dialect
    }

    func start() {
        isRunning = true
        failures = 0
        throttled = false
        backlog.removeAll()
        connect()
        #if DEBUG
        scheduleSimulatedDropouts()
        #endif
    }

    func stop() {
        isRunning = false
        if let primary, primary.isReady, let end = dialect.endOfAudioMessage { primary.send(end) }
        tearDownPrimary()
        dropStandby()
        side.forEach { closeSide($0) }
        backlog.removeAll()
        status = .idle
    }

    func send(_ chunk: Data) {
        guard isRunning else { return }
        if let primary, primary.isReady {
            enqueueAudio(chunk, on: primary)
        } else {
            backlog.append(chunk)
            if backlog.count > Self.maxBacklog {
                backlog.removeFirst(backlog.count - Self.maxBacklog)
            }
        }
    }

    /// The device moved to a different network interface. Opens a socket on
    /// the new path before letting go of the old one.
    func networkPathChanged() {
        guard isRunning, networkAvailable else { return }
        guard let primary, primary.isReady else {
            // Still connecting, maybe over the old path: start over on the new one.
            if status == .reconnecting || status == .connecting {
                failures = 0
                connect()
            }
            return
        }
        guard dialect.supportsSideStreams, standby == nil else { return }
        let connection = makeConnection(isCatchUp: false)
        standby = connection
        open(connection)
    }

    // MARK: - Connection

    /// One WebSocket and the tasks that serve it.
    private final class Connection {
        let stream: SocketStream
        var socket: URLSessionWebSocketTask?
        var outbox: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
        var tasks: [Task<Void, Never>] = []
        var isReady = false
        var isClosed = false
        var hasSentAudio = false
        /// When audio first went out after the last server message.
        var awaitingReplySince: ContinuousClock.Instant?
        /// Audio to send once ready, then end the stream (catch-up only).
        var replay: [Data] = []

        init(stream: SocketStream) {
            self.stream = stream
        }

        func send(_ message: URLSessionWebSocketTask.Message) {
            outbox?.yield(message)
        }

        func close() {
            isClosed = true
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
            outbox?.finish()
            outbox = nil
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
        }
    }

    private func makeConnection(isCatchUp: Bool) -> Connection {
        nextStreamID += 1
        return Connection(stream: SocketStream(id: nextStreamID, isCatchUp: isCatchUp))
    }

    private func connect() {
        guard isRunning else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDownPrimary()
        status = failures == 0 ? .connecting : .reconnecting
        let connection = makeConnection(isCatchUp: false)
        primary = connection
        open(connection)
    }

    /// Fetches a request, then opens the socket and starts its tasks.
    private func open(_ connection: Connection) {
        connection.tasks.append(Task { [weak self, weak connection] in
            guard let self else { return }
            do {
                #if DEBUG
                if self.isBlackholed { throw URLError(.notConnectedToInternet) }
                #endif
                let request = try await self.dialect.makeRequest()
                guard let connection, !connection.isClosed, !Task.isCancelled else { return }
                self.start(connection, request: request)
            } catch SocketSetupError.fail(let message) {
                guard let connection, !connection.isClosed else { return }
                self.connection(connection, failed: .fail(message))
            } catch {
                guard let connection, !connection.isClosed else { return }
                self.connection(connection, failed: .retry("Couldn't connect"))
            }
        })
    }

    private func start(_ connection: Connection, request: URLRequest) {
        var request = request
        request.timeoutInterval = 5
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        connection.socket = socket

        let (stream, continuation) = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
        connection.outbox = continuation
        socket.resume()
        dialect.openingMessages().forEach { continuation.yield($0) }

        connection.tasks.append(Task { [weak self, weak connection] in
            for await message in stream {
                #if DEBUG
                if self?.isBlackholed == true { continue }
                #endif
                do {
                    try await socket.send(message)
                } catch {
                    guard let self, let connection, !connection.isClosed else { return }
                    self.connection(connection, failed: .retry("Send failed"))
                    return
                }
            }
        })

        connection.tasks.append(Task { [weak self, weak connection] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, let connection, !connection.isClosed else { return }
                    #if DEBUG
                    if self.isBlackholed { continue }
                    #endif
                    connection.awaitingReplySince = nil
                    self.connection(connection, received: self.dialect.receive(message, on: connection.stream))
                } catch {
                    guard let self, let connection, !connection.isClosed else { return }
                    self.connection(connection, failed: .retry("Receive failed"))
                    return
                }
            }
        })

        connection.tasks.append(Task { [weak self, weak connection, readyWhenOpen = dialect.readyWhenOpen] in
            // A pong can only come back once the handshake is done, so the
            // first one doubles as the "socket is open" signal.
            if readyWhenOpen {
                let opened = await Self.ping(socket, timeout: .seconds(5))
                guard let self, let connection, !connection.isClosed else { return }
                guard opened else {
                    self.connection(connection, failed: .retry("Handshake timed out"))
                    return
                }
                self.connection(connection, received: .ready)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let alive = await Self.ping(socket, timeout: .seconds(5))
                guard let self, let connection, !connection.isClosed else { return }
                if !alive {
                    self.connection(connection, failed: .retry("Ping timed out"))
                    return
                }
            }
        })

        if let timeout = dialect.stallTimeout {
            connection.tasks.append(Task { [weak self, weak connection] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let connection, !connection.isClosed else { return }
                    if let since = connection.awaitingReplySince, since.duration(to: .now) > timeout {
                        self.connection(connection, failed: .retry("No reply from the server"))
                        return
                    }
                }
            })
        }
    }

    // MARK: - Events

    private func connection(_ connection: Connection, received signal: SocketSignal) {
        if connection === primary {
            handlePrimary(signal)
        } else if connection === standby {
            switch signal {
            case .ready:
                connection.isReady = true
                dialect.sessionDidOpen()
                standbyBecameReady()
            case .retry, .fail:
                dropStandby()
            case .none, .boundary:
                break
            }
        } else {
            switch signal {
            case .ready:
                connection.isReady = true
                dialect.sessionDidOpen()
                if connection.stream.isCatchUp { sendReplay(on: connection) }
            case .retry, .fail:
                // Includes the server finishing after end of audio.
                closeSide(connection)
            case .none, .boundary:
                break
            }
        }
    }

    private func connection(_ connection: Connection, failed signal: SocketSignal) {
        if case .retry(let reason, _) = signal { debugLog("stream \(connection.stream.id) failed: \(reason)") }
        if connection === primary {
            handlePrimary(signal)
        } else if connection === standby {
            dropStandby()
        } else {
            closeSide(connection)
        }
    }

    private func handlePrimary(_ signal: SocketSignal) {
        guard let primary else { return }
        switch signal {
        case .none:
            break
        case .ready:
            guard !primary.isReady else { return }
            primary.isReady = true
            failures = 0
            throttled = false
            status = .live
            dialect.sessionDidOpen()
            flushBacklog(to: primary)
        case .boundary:
            if standby?.isReady == true { handOver() }
        case .retry(_, let isThrottled):
            throttled = throttled || isThrottled
            handleFailure()
        case .fail(let message):
            fail(message)
        }
    }

    private func handleFailure() {
        guard isRunning else { return }

        if let response = primary?.socket?.response as? HTTPURLResponse {
            if response.statusCode == 401 || response.statusCode == 403,
               case .fail(let message) = dialect.keyRejected() {
                fail(message)
                return
            }
            if response.statusCode == 429 { throttled = true }
        }

        // A socket already open on a new path takes over at once.
        if let standby {
            self.standby = nil
            handoverTimer?.cancel()
            tearDownPrimary()
            primary = standby
            if standby.isReady {
                status = .live
                flushBacklog(to: standby)
            } else {
                status = .reconnecting
            }
            return
        }

        tearDownPrimary()
        failures += 1
        status = .reconnecting
        // 0.3 s, 0.6 s, 1.2 s… capped at 6 s, with jitter so clients don't
        // sync up. When the server says too many connections are open, start
        // at 5 s and go up to 30 s, so side sessions can't loop against the limit.
        let base = throttled
            ? min(30.0, 5 * pow(2.0, Double(failures - 1)))
            : min(6.0, 0.3 * pow(2.0, Double(failures - 1)))
        let delay = base * Double.random(in: 0.8...1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.networkAvailable else { return }
            self.connect()
        }
    }

    private func fail(_ message: String) {
        tearDownPrimary()
        dropStandby()
        isRunning = false
        backlog.removeAll()
        status = .failed(message)
    }

    private func tearDownPrimary() {
        guard let primary else { return }
        self.primary = nil
        primary.close()
        if primary.isReady || primary.hasSentAudio { dialect.sessionDidReset(primary.stream) }
    }

    // MARK: - Handover

    private func standbyBecameReady() {
        guard let primary, primary.isReady else {
            // The primary is down; the standby takes over now.
            handleFailure()
            return
        }
        if !dialect.isMidUtterance(on: primary.stream) {
            handOver()
            return
        }
        handoverTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.handoverWait)
            guard !Task.isCancelled else { return }
            self?.handOver()
        }
    }

    /// Moves live audio to the standby and lets the old socket finish.
    private func handOver() {
        guard let standby, standby.isReady, let old = primary else { return }
        handoverTimer?.cancel()
        handoverTimer = nil
        self.standby = nil
        primary = standby
        side.append(old)
        debugLog("handed over from stream \(old.stream.id) to \(standby.stream.id)")
        if let end = dialect.endOfAudioMessage { old.send(end) }
        Task { [weak self, weak old] in
            try? await Task.sleep(for: Self.drainDeadline)
            guard let self, let old, !old.isClosed else { return }
            self.closeSide(old)
        }
    }

    private func dropStandby() {
        handoverTimer?.cancel()
        handoverTimer = nil
        standby?.close()
        standby = nil
    }

    private func closeSide(_ connection: Connection) {
        side.removeAll { $0 === connection }
        guard !connection.isClosed else { return }
        debugLog("closed side stream \(connection.stream.id)")
        connection.close()
        dialect.sideStreamDidEnd(connection.stream)
    }

    // MARK: - Backlog

    private func flushBacklog(to connection: Connection) {
        let speech = Self.trimSilence(backlog)
        let held = backlog.count
        backlog.removeAll()
        let seconds = Double(speech.count) * MicCapture.chunkDuration

        if seconds > Self.catchUpThreshold, dialect.supportsSideStreams {
            let catchUp = makeConnection(isCatchUp: true)
            catchUp.replay = speech
            debugLog("held \(held) chunks, \(speech.count) of speech → catch-up stream \(catchUp.stream.id)")
            side.append(catchUp)
            open(catchUp)
            Task { [weak self, weak catchUp] in
                try? await Task.sleep(for: Self.catchUpDeadline)
                guard let self, let catchUp, !catchUp.isClosed else { return }
                self.closeSide(catchUp)
            }
        } else {
            let limit = Int(Self.maxReplay / MicCapture.chunkDuration)
            if held > 0 { debugLog("held \(held) chunks, replaying \(min(speech.count, limit))") }
            speech.suffix(limit).forEach { enqueueAudio($0, on: connection) }
        }
    }

    private func sendReplay(on connection: Connection) {
        connection.replay.forEach { enqueueAudio($0, on: connection) }
        connection.replay.removeAll()
        if let end = dialect.endOfAudioMessage { connection.send(end) }
    }

    private func enqueueAudio(_ chunk: Data, on connection: Connection) {
        connection.hasSentAudio = true
        if connection.awaitingReplySince == nil { connection.awaitingReplySince = .now }
        connection.send(dialect.audioMessage(chunk))
    }

    /// Cuts silence out of held audio with an energy gate. Speech keeps
    /// 240 ms of padding on each side, and pauses inside speech are kept up
    /// to 800 ms, so endpoint detection still splits utterances.
    static func trimSilence(_ chunks: [Data]) -> [Data] {
        guard !chunks.isEmpty else { return [] }
        let levels = chunks.map(rms)
        // The quietest fifth of the backlog is taken as the noise floor.
        let floor = levels.sorted()[levels.count / 5]
        // About -45 dBFS at the least, so a silent backlog stays silent.
        let threshold = max(floor * 3, 0.0056)
        let speech = levels.map { $0 > threshold }
        guard speech.contains(true) else { return [] }

        let pad = 3, maxPause = 10
        var keep = Array(repeating: false, count: chunks.count)
        for i in speech.indices where speech[i] {
            for j in max(0, i - pad)...min(chunks.count - 1, i + pad) { keep[j] = true }
        }
        // Padding already gives a pause 2 × pad chunks, so add up to the rest.
        let last = keep.lastIndex(of: true)!
        var result: [Data] = []
        var pause = 0
        for i in keep.firstIndex(of: true)!...last {
            if keep[i] {
                pause = 0
                result.append(chunks[i])
            } else {
                pause += 1
                if pause <= maxPause - 2 * pad { result.append(chunks[i]) }
            }
        }
        return result
    }

    /// Root mean square of a PCM16 chunk, 0...1.
    private static func rms(_ chunk: Data) -> Float {
        chunk.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / Float(Int16.max)
                sum += value * value
            }
            return (sum / Float(samples.count)).squareRoot()
        }
    }

    private static func ping(_ socket: URLSessionWebSocketTask, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // URLSession can call this twice when the socket is
                    // cancelled with a ping in flight, so resume only once.
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    socket.sendPing { error in
                        guard !resumed.withLock({ done in defer { done = true }; return done }) else { return }
                        continuation.resume(returning: error == nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static let log = Logger(subsystem: "sh.ian.lively", category: "socket")

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        Self.log.debug("\(text, privacy: .public)")
        #endif
    }

    // MARK: - Simulated dropouts

    #if DEBUG
    private var isBlackholed: Bool {
        blackholeUntil.map { ContinuousClock.now < $0 } ?? false
    }

    /// `-LivelyDropout "AT,FOR"` blackholes the network FOR seconds, starting
    /// AT seconds after listening starts. `-LivelyPathChange AT` reports a
    /// network interface change AT seconds in.
    private func scheduleSimulatedDropouts() {
        let defaults = UserDefaults.standard
        if let spec = defaults.string(forKey: "LivelyDropout") {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(parts[0]))
                    guard let self, self.isRunning else { return }
                    self.debugLog("simulated dropout for \(parts[1]) s")
                    self.blackholeUntil = .now + .seconds(parts[1])
                }
            }
        }
        let pathChange = defaults.double(forKey: "LivelyPathChange")
        if pathChange > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(pathChange))
                guard let self, self.isRunning else { return }
                self.debugLog("simulated path change")
                self.networkPathChanged()
            }
        }
    }
    #endif
}

extension URLSessionWebSocketTask.Message {
    /// Encodes a JSON object as a text frame.
    static func json(_ object: [String: Any]) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .string(String(decoding: data, as: UTF8.self))
    }

    /// The text frame decoded as a JSON object.
    var jsonObject: [String: Any]? {
        let data: Data
        switch self {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
