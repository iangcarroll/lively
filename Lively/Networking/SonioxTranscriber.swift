import Foundation

/// Streams microphone audio to Soniox `stt-rt-v5` with two-way translation:
/// one stream transcribes whichever language is spoken and translates it into
/// the other, so no separate `TranslationService` is needed.
///
/// Protocol: https://soniox.com/docs/stt/rt/real-time-translation and
/// https://soniox.com/docs/stt/api-reference/websocket-api
final class SonioxTranscriber: SpeechEngine, SocketDialect {
    enum Credential {
        /// A long-lived key entered in Settings, for development.
        case apiKey(String)
        /// Temporary keys from Lively's key broker.
        case broker(SonioxKeyProvider)
    }

    struct Configuration {
        var credential: Credential
        var model = "stt-rt-v5"
        var languageA: Language = .english
        var languageB: Language = .chinese
        /// How long Soniox waits before declaring an endpoint (500–3000 ms).
        var maxEndpointDelayMs = 1000
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

    /// The US region, for keys entered in Settings. Broker keys bring their own region's URL.
    private static let defaultEndpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    private let config: Configuration
    private lazy var socket = ResilientSocket(dialect: self)

    /// A run of speech between endpoints, with its translation.
    private struct Segment {
        var id: Int
        var source = ""
        var translation = ""
        var language: Language?
        var isClosed = false

        var event: SpeechSegment {
            SpeechSegment(id: id, source: source, translation: translation, language: language, isClosed: isClosed)
        }
    }

    private var nextSegmentID = 0
    /// The segment receiving spoken words. Nil after an endpoint until
    /// someone speaks again.
    private var open: Segment?
    /// The last closed segment. Its translation can still be arriving.
    private var previous: Segment?
    /// Temporary keys rejected in a row. A temporary key that has expired is
    /// rejected like a bad one, so a few rejections just mean "get a new key".
    private var rejectedTemporaryKeys = 0
    /// The region of the latest connection attempt, until it opens.
    private var connectingRegion: String?

    init(_ configuration: Configuration) {
        config = configuration
    }

    func start() {
        rejectedTemporaryKeys = 0
        connectingRegion = nil
        if case .broker(let provider) = config.credential { provider.startRefreshing() }
        socket.start()
    }

    func send(_ chunk: Data) { socket.send(chunk) }

    func stop() {
        if case .broker(let provider) = config.credential { provider.stopRefreshing() }
        socket.stop()
        closeOpenSegment()
        previous = nil
    }

    func endTurn() {
        closeOpenSegment()
    }

    // MARK: - SocketDialect

    func makeRequest() async throws -> URLRequest {
        let key: String
        let url: URL
        switch config.credential {
        case .apiKey(let value):
            (key, url) = (value, Self.defaultEndpoint)
        case .broker(let provider):
            // The last attempt never opened.
            if let region = connectingRegion { provider.regions.connectFailed(region: region) }
            connectingRegion = nil
            let temporary = try await provider.takeKey()
            connectingRegion = temporary.region
            (key, url) = (temporary.value, temporary.websocketURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    func sessionDidOpen() {
        guard case .broker(let provider) = config.credential, let region = connectingRegion else { return }
        connectingRegion = nil
        provider.regions.connectSucceeded(region: region)
    }

    func openingMessages() -> [URLSessionWebSocketTask.Message] {
        [.json([
            "model": config.model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(MicCapture.sampleRate),
            "num_channels": 1,
            "language_hints": [config.languageA.rawValue, config.languageB.rawValue],
            "enable_language_identification": true,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": config.maxEndpointDelayMs,
            "translation": [
                "type": "two_way",
                "language_a": config.languageA.rawValue,
                "language_b": config.languageB.rawValue,
            ],
        ] as [String: Any])]
    }

    /// Raw PCM goes in binary frames.
    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message { .data(chunk) }
    /// An empty text frame ends the stream; an empty binary frame wouldn't.
    var endOfAudioMessage: URLSessionWebSocketTask.Message? { .string("") }
    /// Soniox only replies when it has tokens, so there's no session ack.
    var readyWhenOpen: Bool { true }
    var rejectedKeyMessage: String { "Your Soniox API key was rejected. Check it in Settings." }

    /// Soniox rejects expired and reused temporary keys with 401, so a
    /// rejected broker key means fetching a new one and reconnecting.
    func keyRejected() -> SocketSignal {
        guard case .broker = config.credential else { return .fail(rejectedKeyMessage) }
        rejectedTemporaryKeys += 1
        guard rejectedTemporaryKeys < 3 else {
            return .fail("Soniox is rejecting Lively's temporary keys. Try again in a few minutes.")
        }
        return .retry("Temporary key rejected")
    }

    func sessionDidReset() {
        // A new session starts a new segment; late tokens from the old one won't come.
        closeOpenSegment()
        previous = nil
        onEvent(.sessionReset)
    }

    func receive(_ message: URLSessionWebSocketTask.Message) -> SocketSignal {
        guard let json = message.jsonObject else { return .none }

        if let code = json["error_code"] as? Int {
            let text = json["error_message"] as? String ?? "Soniox error \(code)"
            switch code {
            case 401, 403: return keyRejected()
            case 402: return .fail("Your Soniox balance or budget is used up.")
            case 400: return .fail("Soniox rejected the request: \(text)")
            // 408, 413 (session too long), 429, 5xx: start a fresh session.
            default: return .retry(text)
            }
        }

        // The key worked.
        rejectedTemporaryKeys = 0

        if let tokens = json["tokens"] as? [[String: Any]], !tokens.isEmpty {
            apply(tokens)
        }

        // The server closes after `finished`; we only stop on purpose, so reconnect.
        if json["finished"] as? Bool == true { return .retry("Session finished") }
        return .none
    }

    // MARK: - Tokens

    /// Final tokens are sent once and kept. Non-final tokens are a guess at
    /// what follows and are replaced by every response, so they're shown but
    /// never stored.
    private func apply(_ tokens: [[String: Any]]) {
        var touched = Set<Int>()

        for token in tokens where token["is_final"] as? Bool == true {
            guard let text = token["text"] as? String else { continue }
            if text == "<end>" || text == "<fin>" {
                guard let id = open?.id else { continue }
                // Report the segment this one replaces as `previous` before it's dropped.
                if let older = previous, touched.remove(older.id) != nil { onEvent(.segment(older.event)) }
                touched.insert(id)
                closeOpenSegment(notify: false)
                continue
            }
            if token["translation_status"] as? String == "translation" {
                let source = (token["source_language"] as? String).flatMap(Language.init(rawValue:))
                if translationTargetIsOpen(sourceLanguage: source, extraText: "") {
                    open?.translation += text
                    if let id = open?.id { touched.insert(id) }
                } else if previous != nil {
                    previous?.translation += text
                    if let id = previous?.id { touched.insert(id) }
                }
            } else {
                openSegmentIfNeeded()
                open?.source += text
                if let language = (token["language"] as? String).flatMap(Language.init(rawValue:)) {
                    open?.language = language
                }
                if let id = open?.id { touched.insert(id) }
            }
        }

        // Overlay this response's non-final tokens on copies of the segments.
        var pendingSource = ""
        var pendingLanguage: Language?
        var pendingOpenTranslation = ""
        var pendingPreviousTranslation = ""
        for token in tokens where token["is_final"] as? Bool != true {
            guard let text = token["text"] as? String, text != "<end>", text != "<fin>" else { continue }
            if token["translation_status"] as? String == "translation" {
                let source = (token["source_language"] as? String).flatMap(Language.init(rawValue:))
                if translationTargetIsOpen(sourceLanguage: source, extraText: pendingSource) {
                    pendingOpenTranslation += text
                } else {
                    pendingPreviousTranslation += text
                }
            } else {
                pendingSource += text
                if let language = (token["language"] as? String).flatMap(Language.init(rawValue:)) {
                    pendingLanguage = language
                }
            }
        }
        if !pendingSource.isEmpty { openSegmentIfNeeded() }
        if !pendingSource.isEmpty || !pendingOpenTranslation.isEmpty, let id = open?.id { touched.insert(id) }
        if !pendingPreviousTranslation.isEmpty, let id = previous?.id { touched.insert(id) }

        if var segment = previous, touched.contains(segment.id) {
            segment.translation += pendingPreviousTranslation
            onEvent(.segment(segment.event))
        }
        if var segment = open, touched.contains(segment.id) {
            segment.source += pendingSource
            segment.translation += pendingOpenTranslation
            segment.language = segment.language ?? pendingLanguage
            onEvent(.segment(segment.event))
        }
    }

    /// Translation follows the words it translates, so it belongs to the open
    /// segment once that has words in the translation's source language, and
    /// to the previous one until then.
    private func translationTargetIsOpen(sourceLanguage: Language?, extraText: String) -> Bool {
        guard let open, !(open.source + extraText).isEmpty else { return false }
        guard let sourceLanguage, let language = open.language else { return true }
        return sourceLanguage == language || previous == nil
    }

    private func openSegmentIfNeeded() {
        guard open == nil else { return }
        open = Segment(id: nextSegmentID)
        nextSegmentID += 1
    }

    private func closeOpenSegment(notify: Bool = true) {
        guard var segment = open else { return }
        segment.isClosed = true
        open = nil
        previous = segment
        if notify { onEvent(.segment(segment.event)) }
    }
}

extension ProviderCredential {
    static let soniox = SonioxKeyProvider.shared == nil
        ? ProviderCredential(
            id: "soniox-api-key",
            name: "Soniox API key",
            help: "Create a key at console.soniox.com."
        )
        : ProviderCredential(
            id: "soniox-api-key",
            name: "Soniox API key (optional)",
            help: "Lively gets short-lived Soniox keys from its key service. For development, a key from console.soniox.com overrides it.",
            isOptional: true
        )
}

extension SpeechProvider {
    static let soniox = SpeechProvider(
        id: "soniox",
        name: "Soniox",
        summary: "Soniox stt-rt-v5 transcribes and translates both ways in one stream, for the lowest latency.",
        credentials: [.soniox],
        options: [],
        makePipeline: { settings in
            let key = settings.credential(.soniox)
            // A key entered in Settings overrides the broker.
            let credential: SonioxTranscriber.Credential = if key.isEmpty, let broker = SonioxKeyProvider.shared {
                .broker(broker)
            } else {
                .apiKey(key)
            }
            return SpeechPipeline(engine: SonioxTranscriber(.init(credential: credential)), translator: nil)
        }
    )
}
