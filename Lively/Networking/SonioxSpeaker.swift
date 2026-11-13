import Foundation

/// Speaks translations aloud with Soniox real-time Text-to-Speech
/// (`tts-rt-v2`), for speech-to-speech mode.
///
/// One WebSocket carries a stream per sentence. Sentences are generated one
/// at a time, in order, and their audio is queued in `SpeechPlayer`, which
/// plays on while the next sentence is generated.
///
/// Protocol: https://soniox.com/docs/translation/sts-translation and
/// https://soniox.com/docs/tts/rt/real-time-generation
final class SonioxSpeaker {
    enum Credential {
        /// A long-lived key entered in Settings, for development.
        case apiKey(String)
        /// Temporary Text-to-Speech keys from Lively's key broker.
        case broker(SonioxKeyProvider)
    }

    static let model = "tts-rt-v2"
    /// Soniox voices speak every language, so one voice serves every pair.
    static let voice = "Adrian"

    /// The credential speech would use, or nil when there's no way to get a Soniox key.
    static func credential(_ settings: AppSettings) -> Credential? {
        let key = settings.credential(.soniox).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { return .apiKey(key) }
        return SonioxKeyProvider.shared.map { .broker($0) }
    }

    /// A problem that stops speech for good, such as a rejected key.
    var onError: (String) -> Void = { _ in }
    let player = SpeechPlayer()

    private struct Line {
        var text: String
        var language: Language
        var output: SpeechPlayer.Output
    }

    private enum SpeakError: Error {
        case fatal(String)
        /// Drop the connection and try the sentence again on a new one.
        case reconnect
    }

    /// The US region, for keys entered in Settings. Broker keys bring their own region's URL.
    private static let defaultEndpoint = URL(string: "wss://tts-rt.soniox.com/tts-websocket")!
    /// Temporary keys open new streams for 300 s; reconnect before that.
    private static let connectionLifetime: Duration = .seconds(240)
    /// Soniox closes a connection after 40 s without a message.
    private static let idleClose: Duration = .seconds(25)

    private let credential: Credential
    private var queue: [Line] = []
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var socketOpenedAt: ContinuousClock.Instant?
    private var idleTimer: Task<Void, Never>?
    private var nextStreamID = 0

    init(credential: Credential) {
        self.credential = credential
    }

    /// Queues a sentence to speak in `language`.
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output = .automatic) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.append(Line(text: text, language: language, output: output))
        idleTimer?.cancel()
        if worker == nil { worker = Task { await run() } }
    }

    /// Stops speaking and drops everything queued.
    func stop() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        idleTimer?.cancel()
        closeSocket()
        player.stop()
    }

    private func run() async {
        while !queue.isEmpty, !Task.isCancelled {
            let line = queue.removeFirst()
            for attempt in 1...2 {
                do {
                    try await generate(line)
                    break
                } catch SpeakError.fatal(let message) {
                    guard !Task.isCancelled else { return }
                    queue.removeAll()
                    closeSocket()
                    onError(message)
                    break
                } catch {
                    if Task.isCancelled { return }
                    closeSocket()
                    // A sentence that fails twice is skipped, not retried forever.
                    if attempt == 2 { break }
                }
            }
        }
        guard !Task.isCancelled else { return }
        worker = nil
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idleClose)
            guard !Task.isCancelled, let self, self.worker == nil else { return }
            self.closeSocket()
        }
    }

    /// Generates one sentence on its own stream and queues its audio.
    private func generate(_ line: Line) async throws {
        // Finish the previous destination before changing the channel map.
        // A missing headset skips private playback instead of using the speaker.
        do {
            guard try await player.prepare(output: line.output) else { return }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakError.fatal(error.localizedDescription)
        }
        try Task.checkCancellation()
        let socket = try await connectedSocket()
        let id = "lively-\(nextStreamID)"
        nextStreamID += 1
        try await socket.send(.json([
            "stream_id": id,
            "model": Self.model,
            "language": line.language.rawValue,
            "voice": Self.voice,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(SpeechPlayer.sampleRate),
        ]))
        try await socket.send(.json(["stream_id": id, "text": line.text, "text_end": true]))

        while true {
            let message = try await socket.receive()
            try Task.checkCancellation()
            guard let json = message.jsonObject else { continue }
            let stream = json["stream_id"] as? String
            // Errors without a stream are about the connection.
            if let code = json["error_code"] as? Int, stream == nil || stream == id {
                switch code {
                case 401, 403:
                    // Temporary keys expire; a key from Settings won't get better.
                    guard case .broker = credential else {
                        throw SpeakError.fatal("Your Soniox API key was rejected for speech. Check it in Settings.")
                    }
                    throw SpeakError.reconnect
                case 402: throw SpeakError.fatal("Your Soniox balance or budget is used up.")
                default:
                    // This sentence failed; `terminated` follows on a live connection.
                    if stream == nil { throw SpeakError.reconnect }
                    continue
                }
            }
            guard stream == id else { continue }
            if let audio = json["audio"] as? String, let data = Data(base64Encoded: audio) {
                player.play(data)
            }
            if json["terminated"] as? Bool == true { return }
        }
    }

    private func connectedSocket() async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running, let socketOpenedAt,
           socketOpenedAt.duration(to: .now) < Self.connectionLifetime {
            return socket
        }
        closeSocket()
        let key: String
        let url: URL
        switch credential {
        case .apiKey(let value):
            (key, url) = (value, Self.defaultEndpoint)
        case .broker(let provider):
            do {
                let temporary = try await provider.takeSpeechKey()
                (key, url) = (temporary.value, temporary.websocketURL)
            } catch SocketSetupError.fail(let message) {
                throw SpeakError.fatal(message)
            }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        self.socket = socket
        socketOpenedAt = .now
        return socket
    }

    private func closeSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketOpenedAt = nil
    }
}
