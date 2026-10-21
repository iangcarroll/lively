import Foundation

/// Streams microphone audio to Voxtral Mini Transcribe Realtime 3 and reports
/// transcript deltas and turn boundaries.
///
/// Built for flaky networks: while the socket is down, audio is held in a
/// bounded backlog and replayed once a new session is up, so speech during a
/// short dropout still gets transcribed.
final class RealtimeTranscriber {
    enum Event {
        case text(String)
        case turnStarted
        case turnEagerEnded
        case turnResumed
        case turnEnded
        /// The server session was replaced; any open turn will not continue.
        case sessionReset
    }

    enum Status: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case failed(String)
    }

    struct Configuration {
        var apiKey: String
        var model: String = AppSettings.transcriptionModel
        var streamingDelayMs: Int
    }

    var onEvent: (Event) -> Void = { _ in }
    var onStatus: (Status) -> Void = { _ in }

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatus(status) } }
    }

    private static let endpoint = URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!
    /// About 20 s of audio at 80 ms per chunk.
    private static let maxBacklog = 250

    private var config: Configuration?
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var outbox: AsyncStream<String>.Continuation?
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
            // Retry right away when the network comes back.
            if networkAvailable, !oldValue, status == .reconnecting { connect() }
        }
    }

    func start(_ configuration: Configuration) {
        config = configuration
        failures = 0
        backlog.removeAll()
        connect()
    }

    func stop() {
        config = nil
        if isReady { enqueue(["type": "input_audio.end"]) }
        tearDown()
        backlog.removeAll()
        status = .idle
    }

    /// Queues one PCM16 chunk. Safe to call while disconnected.
    func send(_ chunk: Data) {
        guard config != nil else { return }
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
        guard let config else { return }
        tearDown()
        generation += 1
        let gen = generation
        status = failures == 0 ? .connecting : .reconnecting

        var request = URLRequest(url: Self.endpoint.appending(queryItems: [
            URLQueryItem(name: "model", value: config.model),
        ]))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket

        let (stream, continuation) = AsyncStream<String>.makeStream()
        outbox = continuation
        socket.resume()

        // Every setting must be in the first update: the session locks once audio arrives.
        enqueue([
            "type": "session.update",
            "session": [
                "audio_format": ["encoding": "pcm_s16le", "sample_rate": Int(MicCapture.sampleRate)],
                "target_streaming_delay_ms": config.streamingDelayMs,
                // No "language": Voxtral detects it, so either person can speak at any time.
                "turn_detection": [
                    "start_threshold": 0.5,
                    "eager_end_threshold": 0.4,
                    "end_threshold": 0.33,
                    "min_silence_ms": 350,
                    "end_timeout_ms": 2000,
                ] as [String: Any],
            ] as [String: Any],
        ])

        // A single writer keeps messages in order.
        connectionTasks.append(Task { [weak self] in
            for await message in stream {
                do {
                    try await socket.send(.string(message))
                } catch {
                    self?.handleFailure(error, generation: gen)
                    return
                }
            }
        })

        connectionTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, gen == self.generation else { return }
                    if case .string(let text) = message { self.handle(text, generation: gen) }
                } catch {
                    self?.handleFailure(error, generation: gen)
                    return
                }
            }
        })

        // Ping keeps NAT mappings alive and finds dead sockets quickly on cellular.
        connectionTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let alive = await Self.ping(socket, timeout: .seconds(5))
                if !alive {
                    self?.handleFailure(URLError(.timedOut), generation: gen)
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
        if isReady || hasSentAudio { onEvent(.sessionReset) }
        isReady = false
        hasSentAudio = false
    }

    private func handleFailure(_ error: Error, generation gen: Int) {
        guard gen == generation, config != nil else { return }

        if let response = socket?.response as? HTTPURLResponse,
           response.statusCode == 401 || response.statusCode == 403 {
            tearDown()
            config = nil
            status = .failed("Your Mistral API key was rejected. Check it in Settings.")
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

    // MARK: - Messages

    private func handle(_ text: String, generation gen: Int) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "session.updated":
            if !isReady {
                isReady = true
                failures = 0
                status = .live
                flushBacklog()
            }
        case "transcription.text.delta":
            if let delta = json["text"] as? String, !delta.isEmpty { onEvent(.text(delta)) }
        case "turn.start":
            onEvent(.turnStarted)
        case "turn.eager_end":
            onEvent(.turnEagerEnded)
        case "turn.resume":
            onEvent(.turnResumed)
        case "turn.end":
            onEvent(.turnEnded)
        case "transcription.done":
            // The server finished this session (e.g. a duration limit). Start a fresh one.
            if config != nil { handleFailure(URLError(.networkConnectionLost), generation: gen) }
        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Transcription error"
            let code = "\(error?["code"] ?? "")"
            if code.contains("401") || message.localizedCaseInsensitiveContains("api key")
                || message.localizedCaseInsensitiveContains("unauthorized") {
                tearDown()
                config = nil
                status = .failed("Your Mistral API key was rejected. Check it in Settings.")
            } else {
                handleFailure(TranscriberError.server(message), generation: gen)
            }
        default:
            break
        }
    }

    private func flushBacklog() {
        let pending = backlog
        backlog.removeAll()
        pending.forEach(enqueueAudio)
    }

    private func enqueueAudio(_ chunk: Data) {
        hasSentAudio = true
        enqueue(["type": "input_audio.append", "audio": chunk.base64EncodedString()])
    }

    private func enqueue(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        outbox?.yield(string)
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

    enum TranscriberError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self { case .server(let message): message }
        }
    }
}
