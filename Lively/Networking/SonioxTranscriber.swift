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
        var languages: LanguagePair
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

        /// `stableTranslation` is the final tokens' part, when non-final ones were added to `translation`.
        func event(isCatchUp: Bool, stableTranslation: String? = nil) -> SpeechSegment {
            SpeechSegment(
                id: id, source: source, translation: translation, stableTranslation: stableTranslation ?? translation,
                language: language, isClosed: isClosed, isCatchUp: isCatchUp
            )
        }
    }

    /// The segments of one server session. Sessions overlap during a
    /// handover and while a catch-up session replays held speech.
    private struct StreamState {
        var isCatchUp: Bool
        /// The segment receiving spoken words. Nil after an endpoint until
        /// someone speaks again.
        var open: Segment?
        /// The last closed segment. Its translation can still be arriving.
        var previous: Segment?
    }

    private var nextSegmentID = 0
    private var streams: [Int: StreamState] = [:]
    /// Temporary keys rejected in a row. A temporary key that has expired is
    /// rejected like a bad one, so a few rejections just mean "get a new key".
    private var rejectedTemporaryKeys = 0
    /// The region of each connection attempt, until it opens or fails.
    /// Attempts overlap when a slow one is raced.
    private var connectingRegions: [Int: String] = [:]

    init(_ configuration: Configuration) {
        config = configuration
    }

    func start() {
        rejectedTemporaryKeys = 0
        connectingRegions.removeAll()
        if case .broker(let provider) = config.credential { provider.startRefreshing() }
        socket.start()
    }

    /// Finalizes what was heard and keeps the session open with keepalives.
    /// The spare key keeps refreshing, in case the session drops meanwhile.
    func pause() { socket.pause() }

    func resume() { socket.resume() }

    func send(_ chunk: Data) { socket.send(chunk) }

    func stop() {
        if case .broker(let provider) = config.credential { provider.stopRefreshing() }
        socket.stop()
        for id in streams.keys { closeOpenSegment(in: id) }
        streams.removeAll()
        connectingRegions.removeAll()
    }

    func endTurn() {
        for (id, state) in streams where !state.isCatchUp { closeOpenSegment(in: id) }
    }

    func networkPathChanged() { socket.networkPathChanged() }

    // MARK: - SocketDialect

    func makeRequest(for stream: SocketStream) async throws -> URLRequest {
        let key: String
        let url: URL
        switch config.credential {
        case .apiKey(let value):
            (key, url) = (value, Self.defaultEndpoint)
        case .broker(let provider):
            let temporary = try await provider.takeKey()
            connectingRegions[stream.id] = temporary.region
            (key, url) = (temporary.value, temporary.websocketURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    func sessionDidOpen(_ stream: SocketStream) {
        guard case .broker(let provider) = config.credential,
              let region = connectingRegions.removeValue(forKey: stream.id) else { return }
        provider.regions.connectSucceeded(region: region)
    }

    func connectFailed(_ stream: SocketStream) {
        guard case .broker(let provider) = config.credential,
              let region = connectingRegions.removeValue(forKey: stream.id) else { return }
        provider.regions.connectFailed(region: region)
    }

    func openingMessages() -> [URLSessionWebSocketTask.Message] {
        [.json([
            "model": config.model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(MicCapture.sampleRate),
            "num_channels": 1,
            "language_hints": config.languages.all.map(\.rawValue),
            "enable_language_identification": true,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": config.maxEndpointDelayMs,
            "translation": [
                "type": "two_way",
                "language_a": config.languages.first.rawValue,
                "language_b": config.languages.second.rawValue,
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
    /// Soniox replies about every 0.12 s while audio flows, and within 1.1 s
    /// at worst (Tools/probe/ASIA_LATENCY.md §2).
    var stallTimeout: Duration? { .milliseconds(2500) }
    /// https://soniox.com/docs/stt/rt/connection-keepalive
    var keepaliveMessage: URLSessionWebSocketTask.Message? { .json(["type": "keepalive"]) }
    /// Finalizes pending tokens, so the last words before a pause show up now.
    var pauseMessage: URLSessionWebSocketTask.Message? { .json(["type": "finalize"]) }
    var supportsSideStreams: Bool { true }

    func isMidUtterance(on stream: SocketStream) -> Bool {
        streams[stream.id]?.open != nil
    }

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

    func sessionDidReset(_ stream: SocketStream) {
        // A new session starts a new segment; late tokens from the old one won't come.
        closeOpenSegment(in: stream.id)
        streams[stream.id] = nil
        onEvent(.sessionReset)
    }

    func sideStreamDidEnd(_ stream: SocketStream) {
        closeOpenSegment(in: stream.id)
        streams[stream.id] = nil
    }

    func receive(_ message: URLSessionWebSocketTask.Message, on stream: SocketStream) -> SocketSignal {
        guard let json = message.jsonObject else { return .none }

        if let code = json["error_code"] as? Int {
            let text = json["error_message"] as? String ?? "Soniox error \(code)"
            switch code {
            case 401, 403: return keyRejected()
            case 402: return .fail("Your Soniox balance or budget is used up.")
            case 400: return .fail("Soniox rejected the request: \(text)")
            // Too many sessions or requests: back off for longer.
            case 429: return .retry(text, throttled: true)
            // 408, 413 (session too long), 5xx: start a fresh session.
            default: return .retry(text)
            }
        }

        // The key worked.
        rejectedTemporaryKeys = 0

        var endedUtterance = false
        if let tokens = json["tokens"] as? [[String: Any]], !tokens.isEmpty {
            var state = streams[stream.id] ?? StreamState(isCatchUp: stream.isCatchUp)
            endedUtterance = apply(tokens, to: &state)
            streams[stream.id] = state
        }

        // The server closes after `finished`; we only stop on purpose, so reconnect.
        if json["finished"] as? Bool == true { return .retry("Session finished") }
        return endedUtterance ? .boundary : .none
    }

    // MARK: - Tokens

    /// Final tokens are sent once and kept. Non-final tokens are a guess at
    /// what follows and are replaced by every response, so they're shown but
    /// never stored. Returns true when an utterance ended.
    private func apply(_ tokens: [[String: Any]], to state: inout StreamState) -> Bool {
        var touched = Set<Int>()
        var endedUtterance = false

        for token in tokens where token["is_final"] as? Bool == true {
            guard let text = token["text"] as? String else { continue }
            if text == "<end>" || text == "<fin>" {
                guard let id = state.open?.id else { continue }
                // Report the segment this one replaces as `previous` before it's dropped.
                if let older = state.previous, touched.remove(older.id) != nil {
                    onEvent(.segment(older.event(isCatchUp: state.isCatchUp)))
                }
                touched.insert(id)
                closeOpenSegment(&state, notify: false)
                endedUtterance = true
                continue
            }
            if token["translation_status"] as? String == "translation" {
                let source = config.languages.language(code: token["source_language"] as? String)
                if Self.translationTargetIsOpen(state, sourceLanguage: source, extraText: "") {
                    state.open?.translation += text
                    if let id = state.open?.id { touched.insert(id) }
                } else if state.previous != nil {
                    state.previous?.translation += text
                    if let id = state.previous?.id { touched.insert(id) }
                }
            } else {
                openSegmentIfNeeded(&state)
                state.open?.source += text
                if let language = config.languages.language(code: token["language"] as? String) {
                    state.open?.language = language
                }
                if let id = state.open?.id { touched.insert(id) }
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
                let source = config.languages.language(code: token["source_language"] as? String)
                if Self.translationTargetIsOpen(state, sourceLanguage: source, extraText: pendingSource) {
                    pendingOpenTranslation += text
                } else {
                    pendingPreviousTranslation += text
                }
            } else {
                pendingSource += text
                if let language = config.languages.language(code: token["language"] as? String) {
                    pendingLanguage = language
                }
            }
        }
        if !pendingSource.isEmpty { openSegmentIfNeeded(&state) }
        if !pendingSource.isEmpty || !pendingOpenTranslation.isEmpty, let id = state.open?.id { touched.insert(id) }
        if !pendingPreviousTranslation.isEmpty, let id = state.previous?.id { touched.insert(id) }

        if var segment = state.previous, touched.contains(segment.id) {
            let stable = segment.translation
            segment.translation += pendingPreviousTranslation
            onEvent(.segment(segment.event(isCatchUp: state.isCatchUp, stableTranslation: stable)))
        }
        if var segment = state.open, touched.contains(segment.id) {
            let stable = segment.translation
            segment.source += pendingSource
            segment.translation += pendingOpenTranslation
            segment.language = segment.language ?? pendingLanguage
            onEvent(.segment(segment.event(isCatchUp: state.isCatchUp, stableTranslation: stable)))
        }
        return endedUtterance
    }

    /// Translation follows the words it translates, so it belongs to the open
    /// segment once that has words in the translation's source language, and
    /// to the previous one until then.
    private static func translationTargetIsOpen(_ state: StreamState, sourceLanguage: Language?, extraText: String) -> Bool {
        guard let open = state.open, !(open.source + extraText).isEmpty else { return false }
        guard let sourceLanguage, let language = open.language else { return true }
        return sourceLanguage == language || state.previous == nil
    }

    private func openSegmentIfNeeded(_ state: inout StreamState) {
        guard state.open == nil else { return }
        state.open = Segment(id: nextSegmentID)
        nextSegmentID += 1
    }

    private func closeOpenSegment(in stream: Int) {
        guard var state = streams[stream] else { return }
        closeOpenSegment(&state)
        streams[stream] = state
    }

    private func closeOpenSegment(_ state: inout StreamState, notify: Bool = true) {
        guard var segment = state.open else { return }
        segment.isClosed = true
        state.open = nil
        state.previous = segment
        if notify { onEvent(.segment(segment.event(isCatchUp: state.isCatchUp))) }
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
        languages: Language.soniox,
        makePipeline: { settings in
            let key = settings.credential(.soniox)
            // A key entered in Settings overrides the broker.
            let credential: SonioxTranscriber.Credential = if key.isEmpty, let broker = SonioxKeyProvider.shared {
                .broker(broker)
            } else {
                .apiKey(key)
            }
            return SpeechPipeline(engine: SonioxTranscriber(.init(credential: credential, languages: settings.languages)), translator: nil)
        }
    )
}
