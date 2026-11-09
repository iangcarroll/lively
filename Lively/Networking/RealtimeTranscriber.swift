import Foundation

/// Streams microphone audio to Voxtral Mini Transcribe Realtime 3 and reports
/// transcript deltas and turn boundaries. Translation is left to a
/// `TranslationService`.
final class RealtimeTranscriber: SpeechEngine, SocketDialect {
    struct Configuration {
        var apiKey: String
        var model: String = AppSettings.transcriptionModel
        var streamingDelayMs: Int
    }

    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void {
        get { socket.onStatus }
        set { socket.onStatus = newValue }
    }
    var networkAvailable: Bool {
        get { socket.networkAvailable }
        set { socket.networkAvailable = newValue }
    }

    /// Turn events arrive as soon as the audio is heard, but transcript text
    /// lags by the streaming delay. A boundary always follows at least
    /// `min_silence_ms` (350 ms) of silence, so the previous turn's last words
    /// arrive within (delay - 350 ms) of it. Waiting about that long keeps
    /// trailing words in their turn without swallowing the next speaker's first.
    var textLag: Duration { .milliseconds(max(60, config.streamingDelayMs - 250)) }

    private static let endpoint = URL(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!

    private let config: Configuration
    private lazy var socket = ResilientSocket(dialect: self)

    init(_ configuration: Configuration) {
        config = configuration
    }

    func start() { socket.start() }
    func stop() { socket.stop() }
    func send(_ chunk: Data) { socket.send(chunk) }

    // MARK: - SocketDialect

    func makeRequest(for stream: SocketStream) -> URLRequest {
        var request = URLRequest(url: Self.endpoint.appending(queryItems: [
            URLQueryItem(name: "model", value: config.model),
        ]))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func openingMessages() -> [URLSessionWebSocketTask.Message] {
        // Every setting must be in the first update: the session locks once audio arrives.
        [.json([
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
        ])]
    }

    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message {
        .json(["type": "input_audio.append", "audio": chunk.base64EncodedString()])
    }

    var endOfAudioMessage: URLSessionWebSocketTask.Message? { .json(["type": "input_audio.end"]) }
    var readyWhenOpen: Bool { false }
    var rejectedKeyMessage: String { "Your Mistral API key was rejected. Check it in Settings." }

    func sessionDidReset(_ stream: SocketStream) {
        onEvent(.sessionReset)
    }

    func receive(_ message: URLSessionWebSocketTask.Message, on stream: SocketStream) -> SocketSignal {
        guard let json = message.jsonObject, let type = json["type"] as? String else { return .none }

        switch type {
        case "session.created", "session.updated":
            return .ready
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
            return .retry("Session ended")
        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Transcription error"
            let code = "\(error?["code"] ?? "")"
            if code.contains("401") || message.localizedCaseInsensitiveContains("api key")
                || message.localizedCaseInsensitiveContains("unauthorized") {
                return .fail(rejectedKeyMessage)
            }
            return .retry(message)
        default:
            break
        }
        return .none
    }
}

extension ProviderCredential {
    static let mistral = ProviderCredential(
        id: "mistral-api-key",
        name: "Mistral API key",
        help: "Create a key at console.mistral.ai."
    )
}

extension SpeechProvider {
    static let voxtralMistral = SpeechProvider(
        id: "voxtral-mistral",
        name: "Voxtral + Mistral",
        summary: "Voxtral Realtime transcribes and detects turns; a Mistral chat model translates each turn.",
        credentials: [.mistral],
        options: [.speed, .translationModel],
        languages: Language.voxtral,
        makePipeline: { settings in
            let key = settings.credential(.mistral)
            let cloud = RealtimeTranscriber(.init(apiKey: key, streamingDelayMs: settings.latency.milliseconds))
            let translator = MistralTranslator(apiKey: key, model: settings.translationModel)
            guard SpeechProvider.onDevice.supports(settings.languages) else {
                return SpeechPipeline(engine: cloud, translator: translator)
            }
            return SpeechPipeline(
                engine: HybridSpeechEngine(
                    local: OfflineSpeechEngine(languages: settings.languages, script: settings.chineseScript),
                    cloud: cloud
                ),
                translator: translator,
                fallbackTranslator: AppleTranslator()
            )
        }
    )
}
