import Foundation

final class AutomaticSonioxTranscriber: SpeechEngine, SocketDialect {
    typealias Credential = SonioxTranscriber.Credential

    struct Configuration {
        var credential: Credential
        var model = "stt-rt-v5"
        var listenerLanguage: Language
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

    private var nextSegmentID = 0
    private var streams: [Int: Epoch] = [:]
    /// Temporary keys rejected in a row. A temporary key that has expired is
    /// rejected like a bad one, so a few rejections just mean "get a new key".
    private var rejectedTemporaryKeys = 0
    /// The region of each connection attempt, until it opens or fails.
    /// Attempts overlap when a slow one is raced.
    private var connectingRegions: [Int: String] = [:]
    /// Audio each stream's server has finalized, from `final_audio_proc_ms`.
    private var finalized: [Int: TimeInterval] = [:]

    init(_ configuration: Configuration) {
        config = configuration
    }

    func start() {
        rejectedTemporaryKeys = 0
        connectingRegions.removeAll()
        if case .broker(let provider) = config.credential { provider.startRefreshing() }
        socket.start()
    }

    func prewarm() {
        rejectedTemporaryKeys = 0
        connectingRegions.removeAll()
        if case .broker(let provider) = config.credential { provider.startRefreshing() }
        socket.prewarm()
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
        finalized.removeAll()
    }

    func endTurn() {
        for (id, var epoch) in streams where !epoch.isCatchUp {
            epoch.locallyClosed = true
            render(&epoch, preview: [], closed: true, sourceFinal: false, evidence: false)
            streams[id] = epoch
        }
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
            let region = connectingRegions.removeValue(forKey: stream.id)
        else { return }
        provider.regions.connectSucceeded(region: region)
    }

    func connectFailed(_ stream: SocketStream) {
        guard case .broker(let provider) = config.credential,
            let region = connectingRegions.removeValue(forKey: stream.id)
        else { return }
        provider.regions.connectFailed(region: region)
    }

    func openingMessages() -> [URLSessionWebSocketTask.Message] {
        [
            .json(
                [
                    "model": config.model,
                    "audio_format": "pcm_s16le",
                    "sample_rate": Int(MicCapture.sampleRate),
                    "num_channels": 1,
                    "enable_language_identification": true,
                    "enable_endpoint_detection": true,
                    "max_endpoint_delay_ms": config.maxEndpointDelayMs,
                    "translation": [
                        "type": "one_way",
                        "target_language": config.listenerLanguage.rawValue,
                    ],
                ] as [String: Any])
        ]
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
    /// Every response carries `final_audio_proc_ms`, so audio Soniox hadn't
    /// finalized when a session drops is sent again on the next one.
    var reportsFinalizedAudio: Bool { true }

    func finalizedAudio(on stream: SocketStream) -> TimeInterval {
        finalized[stream.id] ?? 0
    }

    func isMidUtterance(on stream: SocketStream) -> Bool {
        streams[stream.id]?.hasContent == true
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
        finalized[stream.id] = nil
        onEvent(.sessionReset)
    }

    func sideStreamDidEnd(_ stream: SocketStream) {
        closeOpenSegment(in: stream.id)
        streams[stream.id] = nil
        finalized[stream.id] = nil
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
        if let ms = (json["final_audio_proc_ms"] as? NSNumber)?.doubleValue {
            finalized[stream.id] = ms / 1000
        }

        var endedUtterance = false
        if let tokens = json["tokens"] as? [[String: Any]],
            !tokens.isEmpty || streams[stream.id]?.hasContent == true
        {
            var state = streams[stream.id] ?? Epoch(isCatchUp: stream.isCatchUp)
            endedUtterance = apply(tokens, to: &state)
            streams[stream.id] = state
        }

        // The server closes after `finished`; we only stop on purpose, so reconnect.
        if json["finished"] as? Bool == true { return .retry("Session finished") }
        return endedUtterance ? .boundary : .none
    }

    // MARK: - Automatic source and translation lanes

    private enum Kind { case listener, foreign, unknown }
    private struct Piece {
        var text: String
        var language: Language?
        var kind: Kind
    }
    private struct Group {
        var anchor: Int
        var pieces: [Piece]
        var kind: Kind
        var text: String { pieces.map(\.text).joined() }
    }
    private struct Native {
        var id: Int
        var language: Language?
        var explicitLanguage: Bool
        var sourceAnchor: Int?
        var text: String
    }
    private struct Epoch {
        var isCatchUp: Bool
        var source: [Piece] = []
        var native: [Native] = []
        var nativeLeading: (language: Language?, text: String)?
        var sourceIDs: [Int: Int] = [:]
        var shown: [Int: AutoSpeechSegment] = [:]
        var previewNativeID: Int?
        var locallyClosed = false
        var hasContent: Bool { !source.isEmpty || !native.isEmpty || !shown.isEmpty }
    }

    private func allocateID() -> Int {
        defer { nextSegmentID += 1 }
        return nextSegmentID
    }

    private func language(_ value: Any?) -> Language? {
        guard let raw = value as? String else { return nil }
        let code = raw.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(
            String.init)
        guard let code, Language.soniox.contains(Language(code)) else { return nil }
        return Language(code)
    }

    private func meaningful(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    private func piece(_ token: [String: Any], text: String) -> Piece {
        let lang = language(token["language"])
        let kind: Kind
        if let lang {
            kind = lang == config.listenerLanguage ? .listener : .foreign
        } else {
            kind = token["translation_status"] as? String == "original" ? .foreign : .unknown
        }
        return Piece(text: text, language: lang, kind: kind)
    }

    private func groups(_ source: [Piece]) -> [Group] {
        var result: [Group] = []
        for (index, piece) in source.enumerated() {
            let languageBoundary =
                result.last.map { previous in
                    previous.kind == .foreign && piece.kind == .foreign
                        && meaningful(piece.text) && endsSentence(previous.text)
                        && piece.language != nil && coherentLanguage(previous) != nil
                        && piece.language != coherentLanguage(previous)
                } ?? false
            if let last = result.indices.last,
                !languageBoundary,
                result[last].kind == piece.kind || piece.kind == .unknown || result[last].kind == .unknown
            {
                if result[last].kind == .unknown { result[last].kind = piece.kind }
                result[last].pieces.append(piece)
            } else {
                result.append(Group(anchor: index, pieces: [piece], kind: piece.kind))
            }
        }
        // A proper name can have a different word-level language tag without
        // indicating a new speaker. Fold it only when both surrounding source
        // lanes agree and neither earlier run has ended its sentence.
        var index = 1
        while index + 1 < result.count {
            let previous = result[index - 1]
            let middle = result[index]
            let following = result[index + 1]
            if previous.kind == following.kind,
                !endsSentence(previous.text), !endsSentence(middle.text)
            {
                result[index - 1].pieces += middle.pieces + following.pieces
                result.removeSubrange(index...index + 1)
                index = max(1, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    private func coherentLanguage(_ group: Group) -> Language? {
        let known = Set(
            group.pieces.filter {
                meaningful($0.text) && ($0.kind == group.kind || $0.kind == .unknown)
            }.compactMap(\.language))
        return known.count == 1 ? known.first : nil
    }

    private func sourceID(_ anchor: Int, in epoch: inout Epoch) -> Int {
        if let id = epoch.sourceIDs[anchor] { return id }
        let id = allocateID()
        epoch.sourceIDs[anchor] = id
        return id
    }

    private func incomingLanguage(_ token: [String: Any], in epoch: Epoch) -> Language? {
        if token["source_language"] != nil { return language(token["source_language"]) }
        let known = Set(groups(epoch.source).filter { $0.kind == .foreign }.compactMap(coherentLanguage))
        return known.count == 1 ? known.first : nil
    }

    private func nativePlacement(
        for source: Language?, in epoch: Epoch, originals: [Group], isMeaningful: Bool
    ) -> (existing: Int?, anchor: Int?) {
        if let last = epoch.native.indices.last, epoch.native[last].language == source {
            let followedBySource =
                epoch.native[last].sourceAnchor.flatMap { anchor in
                    originals.firstIndex { $0.anchor == anchor }
                }.map { index in
                    originals.dropFirst(index + 1).contains { meaningful($0.text) }
                } ?? false
            if !isMeaningful || !followedBySource || !nativeSentenceIsComplete(epoch.native[last].text) {
                return (last, nil)
            }
        }
        let claimed = Set(epoch.native.compactMap(\.sourceAnchor))
        let candidates = originals.filter {
            $0.kind == .foreign && coherentLanguage($0) == source && source != nil
                && !claimed.contains($0.anchor)
        }
        return (nil, candidates.count == 1 ? candidates[0].anchor : nil)
    }

    private func appendNative(_ token: [String: Any], text: String, to epoch: inout Epoch) {
        if let target = language(token["language"]), target != config.listenerLanguage { return }
        if let raw = token["language"] as? String, !raw.isEmpty, language(raw) == nil { return }
        let source =
            !meaningful(text) && token["source_language"] == nil
            ? epoch.native.last?.language : incomingLanguage(token, in: epoch)
        if source == config.listenerLanguage { return }
        let originals = groups(epoch.source)
        let placement = nativePlacement(
            for: source, in: epoch, originals: originals, isMeaningful: meaningful(text))
        if let last = placement.existing {
            epoch.native[last].text += text
            epoch.native[last].explicitLanguage =
                epoch.native[last].explicitLanguage || language(token["source_language"]) != nil
            return
        }
        guard epoch.source.contains(where: { meaningful($0.text) }) else { return }
        guard meaningful(text) else {
            let previous = epoch.nativeLeading
            let compatible = previous?.language == nil || source == nil || previous?.language == source
            epoch.nativeLeading = (source, (compatible ? previous?.text ?? "" : "") + text)
            return
        }
        let leading =
            epoch.nativeLeading.map {
                $0.language == nil || source == nil || $0.language == source ? $0.text : ""
            } ?? ""
        epoch.nativeLeading = nil
        for group in originals { _ = sourceID(group.anchor, in: &epoch) }
        let anchor = placement.anchor
        let id = anchor.map { sourceID($0, in: &epoch) } ?? epoch.previewNativeID ?? allocateID()
        epoch.previewNativeID = nil
        epoch.native.append(
            Native(
                id: id, language: source, explicitLanguage: language(token["source_language"]) != nil,
                sourceAnchor: anchor, text: leading + text))
    }

    private func apply(_ tokens: [[String: Any]], to epoch: inout Epoch) -> Bool {
        var preview: [[String: Any]] = []
        var boundary = false
        for token in tokens {
            guard let text = token["text"] as? String else { continue }
            guard token["is_final"] as? Bool == true else {
                preview.append(token)
                continue
            }
            if text == "<end>" || text == "<fin>" {
                render(&epoch, preview: [], closed: true, sourceFinal: true, evidence: true)
                epoch = Epoch(isCatchUp: epoch.isCatchUp)
                preview.removeAll()
                boundary = true
            } else if token["translation_status"] as? String == "translation" {
                appendNative(token, text: text, to: &epoch)
            } else {
                epoch.source.append(piece(token, text: text))
            }
        }
        render(&epoch, preview: preview, closed: epoch.locallyClosed, sourceFinal: false, evidence: false)
        return boundary
    }

    private func endsSentence(_ text: String) -> Bool {
        let closers = "\"'”’)]}"
        guard let last = text.last(where: { !$0.isWhitespace && !closers.contains($0) }) else { return false }
        return ".?!。！？".contains(last)
    }

    private func nativeSentenceIsComplete(_ text: String) -> Bool {
        let trimmed = Filler.strip(text, in: config.listenerLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && ConversationStore.completeSentences(in: trimmed) == trimmed
    }

    private func render(
        _ epoch: inout Epoch, preview: [[String: Any]], closed: Bool,
        sourceFinal: Bool, evidence: Bool
    ) {
        let volatile = preview.compactMap { token -> Piece? in
            guard token["translation_status"] as? String != "translation",
                let text = token["text"] as? String, text != "<end>", text != "<fin>"
            else { return nil }
            return piece(token, text: text)
        }
        let canonical = groups(epoch.source)
        let originals = groups(epoch.source + volatile)
        var desired: [Int: AutoSpeechSegment] = [:]
        for group in originals {
            let id = sourceID(group.anchor, in: &epoch)
            let lang = coherentLanguage(group)
            let fixed = canonical.first { $0.anchor == group.anchor }
            let corroborated =
                lang.map { value in
                    epoch.native.contains { $0.language == value && $0.explicitLanguage }
                } ?? false
            let finalLanguage =
                lang != nil && fixed.flatMap(coherentLanguage) == lang
                && group.pieces.count == fixed?.pieces.count
            let partnerEvidence =
                sourceFinal && evidence && !epoch.isCatchUp && finalLanguage
                && group.kind == .foreign && corroborated
            let fallback =
                sourceFinal && evidence && group.kind == .foreign
                && lang != nil && epoch.native.isEmpty
            desired[id] = AutoSpeechSegment(
                id: id, source: group.text, language: lang,
                languageIsFinal: finalLanguage, target: fallback ? config.listenerLanguage : nil,
                translation: "", stableTranslation: "", isClosed: closed,
                isSourceFinal: sourceFinal && group.pieces.count == fixed?.pieces.count,
                isCatchUp: epoch.isCatchUp, isPartnerEvidence: partnerEvidence)
        }
        for native in epoch.native {
            let group = native.sourceAnchor.flatMap { anchor in canonical.first { $0.anchor == anchor } }
            let finalLanguage =
                desired[native.id]?.languageIsFinal == true && native.language != nil
                && group.flatMap(coherentLanguage) == native.language
            var segment =
                desired[native.id]
                ?? AutoSpeechSegment(
                    id: native.id, source: "", language: native.language,
                    languageIsFinal: false, target: config.listenerLanguage, translation: "",
                    stableTranslation: "",
                    isClosed: closed, isSourceFinal: sourceFinal, isCatchUp: epoch.isCatchUp)
            segment.language = native.language
            segment.languageIsFinal = finalLanguage
            segment.isPartnerEvidence =
                sourceFinal && evidence && !epoch.isCatchUp && finalLanguage && native.explicitLanguage
            segment.target = config.listenerLanguage
            segment.translation = native.text
            segment.stableTranslation = native.text
            desired[native.id] = segment
        }
        var previewID: Int?
        var previewLanguage: Language?
        for token in preview where token["translation_status"] as? String == "translation" {
            guard let text = token["text"] as? String, text != "<end>", text != "<fin>" else { continue }
            if let raw = token["language"] as? String, !raw.isEmpty, language(raw) != config.listenerLanguage
            {
                continue
            }
            let source = incomingLanguage(token, in: epoch)
            if source == config.listenerLanguage { continue }
            if previewID != nil, previewLanguage != source { continue }
            let id: Int
            if let previewID {
                id = previewID
            } else {
                let placement = nativePlacement(
                    for: source, in: epoch, originals: originals, isMeaningful: meaningful(text))
                if let existing = placement.existing {
                    id = epoch.native[existing].id
                } else if let anchor = placement.anchor {
                    id = sourceID(anchor, in: &epoch)
                } else {
                    id = epoch.previewNativeID ?? allocateID()
                    epoch.previewNativeID = id
                }
            }
            previewID = id
            previewLanguage = source
            var segment =
                desired[id]
                ?? AutoSpeechSegment(
                    id: id, source: "", language: source,
                    languageIsFinal: false, target: config.listenerLanguage, translation: "",
                    stableTranslation: "",
                    isClosed: closed, isSourceFinal: false, isCatchUp: epoch.isCatchUp)
            segment.target = config.listenerLanguage
            segment.language = source
            segment.languageIsFinal = segment.languageIsFinal && !segment.source.isEmpty
            segment.isPartnerEvidence = false
            segment.translation += text
            desired[id] = segment
        }
        for (id, previous) in epoch.shown.sorted(by: { $0.key < $1.key }) where desired[id] == nil {
            var cleared = previous
            cleared.source = ""
            cleared.translation = ""
            cleared.stableTranslation = ""
            cleared.languageIsFinal = false
            cleared.isPartnerEvidence = false
            cleared.isClosed = true
            cleared.isSourceFinal = false
            onEvent(.autoSegment(cleared))
        }
        for (id, segment) in desired.sorted(by: { $0.key < $1.key }) {
            if epoch.shown[id] != segment { onEvent(.autoSegment(segment)) }
        }
        epoch.shown = desired
    }

    private func closeOpenSegment(in stream: Int) {
        guard var epoch = streams[stream] else { return }
        render(&epoch, preview: [], closed: true, sourceFinal: false, evidence: false)
        streams[stream] = epoch
    }
}
