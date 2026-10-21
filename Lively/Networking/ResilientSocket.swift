import Foundation

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
    func receive(_ message: URLSessionWebSocketTask.Message) -> SocketSignal
    /// The session was torn down after it had started.
    func sessionDidReset()
    /// The connection is up and can take audio.
    func sessionDidOpen()
}

extension SocketDialect {
    func keyRejected() -> SocketSignal { .fail(rejectedKeyMessage) }
    func sessionDidOpen() {}
}

enum SocketSetupError: Error {
    /// Permanent: stop and report.
    case fail(String)
}

enum SocketSignal {
    case none
    /// The session accepted its settings and can take audio.
    case ready
    /// Transient: reconnect with backoff.
    case retry(String)
    /// Permanent: stop and report.
    case fail(String)
}

/// A WebSocket that survives flaky networks, shared by all speech engines.
///
/// - A single writer task keeps messages in order.
/// - Pings every 4 s keep NAT mappings alive and find dead sockets quickly.
/// - Reconnects use jittered exponential backoff, and retry at once when the
///   network comes back.
/// - While the socket is down, audio is held in a bounded backlog and
///   replayed once a new session is up, so speech during a short dropout
///   still gets transcribed.
final class ResilientSocket {
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }

    private(set) var status: SpeechEngineStatus = .idle {
        didSet { if status != oldValue { onStatus(status) } }
    }

    /// About 20 s of audio at 80 ms per chunk.
    private static let maxBacklog = 250

    private unowned let dialect: SocketDialect
    private var isRunning = false
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var outbox: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    private var connectionTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?

    /// Incremented for every connection so stale callbacks are ignored.
    private var generation = 0
    private var isReady = false
    private var hasSentAudio = false
    private var failures = 0
    private var backlog: [Data] = []
    var networkAvailable = true {
        didSet {
            if networkAvailable, !oldValue, status == .reconnecting { connect() }
        }
    }

    init(dialect: SocketDialect) {
        self.dialect = dialect
    }

    func start() {
        isRunning = true
        failures = 0
        backlog.removeAll()
        connect()
    }

    func stop() {
        isRunning = false
        if isReady, let end = dialect.endOfAudioMessage { outbox?.yield(end) }
        tearDown()
        backlog.removeAll()
        status = .idle
    }

    func send(_ chunk: Data) {
        guard isRunning else { return }
        if isReady {
            enqueueAudio(chunk)
        } else {
            backlog.append(chunk)
            if backlog.count > Self.maxBacklog {
                backlog.removeFirst(backlog.count - Self.maxBacklog)
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard isRunning else { return }
        tearDown()
        generation += 1
        let gen = generation
        status = failures == 0 ? .connecting : .reconnecting

        connectionTasks.append(Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.dialect.makeRequest()
                guard gen == self.generation, !Task.isCancelled else { return }
                self.open(request, generation: gen)
            } catch SocketSetupError.fail(let message) {
                guard gen == self.generation else { return }
                self.fail(message)
            } catch {
                self.handleFailure(generation: gen)
            }
        })
    }

    private func open(_ request: URLRequest, generation gen: Int) {
        var request = request
        request.timeoutInterval = 10
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket

        let (stream, continuation) = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
        outbox = continuation
        socket.resume()
        dialect.openingMessages().forEach { continuation.yield($0) }

        connectionTasks.append(Task { [weak self] in
            for await message in stream {
                do {
                    try await socket.send(message)
                } catch {
                    self?.handleFailure(generation: gen)
                    return
                }
            }
        })

        connectionTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, gen == self.generation else { return }
                    self.handle(self.dialect.receive(message), generation: gen)
                } catch {
                    self?.handleFailure(generation: gen)
                    return
                }
            }
        })

        connectionTasks.append(Task { [weak self, readyWhenOpen = dialect.readyWhenOpen] in
            // A pong can only come back once the handshake is done, so the
            // first one doubles as the "socket is open" signal.
            if readyWhenOpen {
                guard await Self.ping(socket, timeout: .seconds(10)) else {
                    self?.handleFailure(generation: gen)
                    return
                }
                guard let self, gen == self.generation else { return }
                self.handle(.ready, generation: gen)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                if !(await Self.ping(socket, timeout: .seconds(5))) {
                    self?.handleFailure(generation: gen)
                    return
                }
            }
        })
    }

    private func tearDown() {
        connectionTasks.forEach { $0.cancel() }
        connectionTasks.removeAll()
        reconnectTask?.cancel()
        reconnectTask = nil
        outbox?.finish()
        outbox = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if isReady || hasSentAudio { dialect.sessionDidReset() }
        isReady = false
        hasSentAudio = false
    }

    private func handle(_ signal: SocketSignal, generation gen: Int) {
        switch signal {
        case .none:
            break
        case .ready:
            guard !isReady else { return }
            isReady = true
            failures = 0
            status = .live
            dialect.sessionDidOpen()
            let pending = backlog
            backlog.removeAll()
            pending.forEach(enqueueAudio)
        case .retry:
            handleFailure(generation: gen)
        case .fail(let message):
            fail(message)
        }
    }

    private func handleFailure(generation gen: Int) {
        guard gen == generation, isRunning else { return }

        if let response = socket?.response as? HTTPURLResponse,
           response.statusCode == 401 || response.statusCode == 403,
           case .fail(let message) = dialect.keyRejected() {
            fail(message)
            return
        }

        tearDown()
        failures += 1
        status = .reconnecting
        // 0.3 s, 0.6 s, 1.2 s… capped at 6 s, with jitter so clients don't sync up.
        let base = min(6.0, 0.3 * pow(2.0, Double(failures - 1)))
        let delay = base * Double.random(in: 0.8...1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.networkAvailable else { return }
            self.connect()
        }
    }

    private func fail(_ message: String) {
        tearDown()
        isRunning = false
        backlog.removeAll()
        status = .failed(message)
    }

    private func enqueueAudio(_ chunk: Data) {
        hasSentAudio = true
        outbox?.yield(dialect.audioMessage(chunk))
    }

    private static func ping(_ socket: URLSessionWebSocketTask, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    socket.sendPing { error in continuation.resume(returning: error == nil) }
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
