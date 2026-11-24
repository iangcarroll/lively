import Foundation

/// Streams microphone audio to Soniox `stt-rt-v6` with two-way translation:
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
        var model = "stt-rt-v6"
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

    private struct SourcePiece {
        var text: String
        var language: Language?
    }

    private struct PendingTranslation {
        var source: Language
        var text: String
    }

    /// Speech with one confirmed translation direction, within a provider turn.
    private struct Segment {
        var id: Int
        var source = ""
        var translation = ""
        var language: Language?
        var sourceLanguages = Set<Language>()
        var sourcePieces: [SourcePiece] = []
        /// A different language can be an embedded name or a quick reply.
        /// Only final translation metadata can confirm another direction.
        var deferredSource: [SourcePiece] = []
        /// A folded original is not receipted by a later chunk of the earlier
        /// translation. Retain its provenance until directions are resolved.
        var unreceiptedFoldStart: Int?
        var hasAmbiguousSource = false
        var pendingTranslations: [PendingTranslation] = []
        var translationSource: Language?
        var isClosed = false
        var lastShownLanguage: Language?
        var hasProvisionalOverlay = false

        /// `stableTranslation` is the final tokens' part, when non-final ones were added to `translation`.
        func event(isCatchUp: Bool, stableTranslation: String? = nil) -> SpeechSegment {
            let stable = translationSource == language ? (stableTranslation ?? translation) : ""
            return SpeechSegment(
                id: id, source: source, translation: translation, stableTranslation: stable,
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
    }

    private var nextSegmentID = 0
    private var streams: [Int: StreamState] = [:]
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
        // A local silence timeout can precede the service's final tokens.
        // Close the UI turn, but keep its ID until the provider's boundary.
        for (id, var state) in streams where !state.isCatchUp {
            guard var segment = state.open else { continue }
            segment.isClosed = true
            emitConfirmedOrRetract(segment, isCatchUp: false)
            segment.lastShownLanguage = segment.language ?? segment.lastShownLanguage
            segment.hasProvisionalOverlay = false
            state.open = segment
            streams[id] = state
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
                    "enable_reconnect": true,
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
                ] as [String: Any])
        ]
    }

    /// Raw PCM goes in binary frames.
    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message { .data(chunk) }
    /// An empty text frame ends the stream; an empty binary frame wouldn't.
    var endOfAudioMessage: URLSessionWebSocketTask.Message? { .string("") }
    /// Audio can start at handshake, even when the server omits the reconnect offer.
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
            !tokens.isEmpty || streams[stream.id]?.open != nil
        {
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
        var touched = false
        var endedUtterance = false
        for token in tokens where token["is_final"] as? Bool == true {
            guard let text = token["text"] as? String else { continue }
            if text == "<end>" || text == "<fin>" {
                // Provider boundaries finalize the transcription and its
                // translation. Token language changes are not speaker IDs.
                closeOpenSegment(&state, providerBoundary: true)
                touched = false
                endedUtterance = true
                continue
            }
            if token["translation_status"] as? String == "translation" {
                guard var segment = state.open, !segment.source.isEmpty,
                    let source = translationSource(
                        token, fallback: segment.pendingTranslations.last?.source ?? segment.translationSource
                    ),
                    meaningful(text) || source == segment.pendingTranslations.last?.source
                        || source == segment.translationSource
                else { continue }
                if segment.hasAmbiguousSource, segment.translationSource != nil,
                    !segment.pendingTranslations.isEmpty || segment.translationSource != source
                {
                    if segment.pendingTranslations.last?.source == source {
                        segment.pendingTranslations[segment.pendingTranslations.count - 1].text += text
                    } else {
                        segment.pendingTranslations.append(PendingTranslation(source: source, text: text))
                    }
                    state.open = segment
                    touched = true
                    continue
                }
                if let current = segment.translationSource, current != source {
                    let matchingDeferred = segment.deferredSource.contains {
                        $0.language == source && meaningful($0.text)
                    }
                    if segment.unreceiptedFoldStart != nil || !matchingDeferred {
                        // A provider final can be certain even when caption
                        // ownership is not. Keep its actual directed output.
                        segment.hasAmbiguousSource = true
                        segment.pendingTranslations.append(PendingTranslation(source: source, text: text))
                        state.open = segment
                        touched = true
                        continue
                    }
                    let reply = segment.deferredSource
                    segment.deferredSource = []
                    segment.isClosed = true
                    emitConfirmedOrRetract(segment, isCatchUp: state.isCatchUp)
                    segment = Segment(id: nextSegmentID)
                    nextSegmentID += 1
                    for piece in reply { appendOwnedSource(piece, to: &segment) }
                }
                if segment.translationSource == nil { deferTrailingSource(&segment, for: source) }
                segment.translation += text
                segment.translationSource = source
                segment.language = source
                state.open = segment
                touched = true
            } else {
                openSegmentIfNeeded(&state)
                if var segment = state.open {
                    appendSource(sourcePiece(token, text: text), to: &segment)
                    state.open = segment
                }
                touched = true
            }
        }

        // Provisional text is a replacement overlay, including embedded
        // foreign words. It never commits a speaker or a speech prefix.
        var pendingSource: [SourcePiece] = []
        for token in tokens
        where token["is_final"] as? Bool != true && token["translation_status"] as? String != "translation" {
            guard let text = token["text"] as? String, text != "<end>", text != "<fin>" else { continue }
            pendingSource.append(sourcePiece(token, text: text))
        }
        if !pendingSource.isEmpty { openSegmentIfNeeded(&state) }
        guard var segment = state.open else { return endedUtterance }
        let stable = segment.translation
        for piece in pendingSource { appendSource(piece, to: &segment) }
        var pendingTranslationSource: Language?
        for token in tokens
        where token["is_final"] as? Bool != true && token["translation_status"] as? String == "translation" {
            guard !segment.source.isEmpty,
                segment.pendingTranslations.isEmpty,
                let text = token["text"] as? String, text != "<end>", text != "<fin>",
                let source = translationSource(
                    token, fallback: pendingTranslationSource ?? segment.translationSource),
                meaningful(text) || source == pendingTranslationSource || source == segment.translationSource,
                segment.translationSource == nil || segment.translationSource == source,
                pendingTranslationSource == nil || pendingTranslationSource == source
            else { continue }
            segment.translation += text
            pendingTranslationSource = source
            touched = true
        }
        segment.language =
            segment.translationSource ?? pendingTranslationSource
            ?? sourceLanguage(segment.sourceLanguages)
        if touched || !pendingSource.isEmpty || segment.hasProvisionalOverlay {
            if emit(segment, isCatchUp: state.isCatchUp, stableTranslation: stable) {
                state.open?.lastShownLanguage = segment.language
                state.open?.hasProvisionalOverlay = !pendingSource.isEmpty || pendingTranslationSource != nil
            } else if let confirmed = state.open {
                emitConfirmedOrRetract(confirmed, isCatchUp: state.isCatchUp)
                state.open?.lastShownLanguage = confirmed.language ?? confirmed.lastShownLanguage
                state.open?.hasProvisionalOverlay = false
            }
        }
        return endedUtterance
    }

    /// Mixed token tags describe multilingual text, not a change of speaker.
    /// Wait for translation metadata when they disagree about the sentence.
    private func sourceLanguage(_ languages: Set<Language>) -> Language? {
        languages.count == 1 ? languages.first : nil
    }

    private func sourcePiece(_ token: [String: Any], text: String) -> SourcePiece {
        let language = meaningful(text) ? configuredLanguage(token["language"] as? String) : nil
        return SourcePiece(text: text, language: language)
    }

    private func appendOwnedSource(_ piece: SourcePiece, to segment: inout Segment) {
        segment.source += piece.text
        segment.sourcePieces.append(piece)
        if let language = piece.language { segment.sourceLanguages.insert(language) }
        segment.language = segment.translationSource ?? sourceLanguage(segment.sourceLanguages)
    }

    private func appendSource(_ piece: SourcePiece, to segment: inout Segment) {
        var foldedName = false
        if let current = segment.translationSource {
            if segment.hasAmbiguousSource {
                segment.deferredSource.append(piece)
                return
            }
            if piece.language == current {
                // A source-language continuation folds an embedded name back
                // into an unfinished sentence. A completed reply can instead
                // precede another original source before translations catch up.
                if segment.deferredSource.contains(where: { endsSentence($0.text) }) {
                    segment.deferredSource.append(piece)
                    return
                }
                if !segment.deferredSource.isEmpty, endsSentence(segment.source) {
                    segment.hasAmbiguousSource = true
                    segment.deferredSource.append(piece)
                    return
                }
                foldedName = !segment.deferredSource.isEmpty
                if foldedName, segment.unreceiptedFoldStart == nil {
                    segment.unreceiptedFoldStart = segment.sourcePieces.count
                }
                foldDeferredSource(&segment)
            } else if !segment.deferredSource.isEmpty || (piece.language != nil && piece.language != current)
            {
                segment.deferredSource.append(piece)
                return
            }
        }
        appendOwnedSource(piece, to: &segment)
    }

    private func foldDeferredSource(_ segment: inout Segment) {
        let deferred = segment.deferredSource
        segment.deferredSource = []
        for piece in deferred { appendOwnedSource(piece, to: &segment) }
    }

    private func setOwnedSource(_ pieces: [SourcePiece], in segment: inout Segment) {
        segment.source = ""
        segment.sourcePieces = []
        segment.sourceLanguages = []
        for piece in pieces { appendOwnedSource(piece, to: &segment) }
    }

    private func deferTrailingSource(_ segment: inout Segment, for source: Language) {
        // The first translation may arrive after both sides have spoken.
        // Preserve an opposite-language suffix until its translation either
        // confirms a reply or the provider endpoint keeps it in this sentence.
        let last = segment.sourcePieces.lastIndex(where: { $0.language == source }) ?? -1
        let candidates = segment.sourcePieces.indices.filter {
            segment.sourcePieces[$0].language != nil && segment.sourcePieces[$0].language != source
        }
        let sentenceStart = candidates.first { hasSentenceBoundary(before: $0, in: segment.sourcePieces) }
        let firstOpposite = candidates.first
        let containsReturn =
            firstOpposite.map { first in
                segment.sourcePieces.indices.contains {
                    $0 > first && segment.sourcePieces[$0].language == source
                }
            } ?? false
        let ambiguous = containsReturn && last >= 0 && sentenceStart != firstOpposite
        guard
            let start = ambiguous ? firstOpposite : (sentenceStart ?? candidates.first(where: { $0 > last })),
            segment.sourcePieces[..<start].contains(where: { meaningful($0.text) }),
            last >= 0
                || segment.sourcePieces[..<start].contains(where: {
                    $0.language == nil && meaningful($0.text)
                })
        else { return }
        let prefix = Array(segment.sourcePieces[..<start])
        segment.hasAmbiguousSource = ambiguous
        segment.deferredSource = Array(segment.sourcePieces[start...])
        setOwnedSource(prefix, in: &segment)
    }

    private func closeAmbiguousDirections(_ segment: Segment, isCatchUp: Bool) {
        guard let firstSource = segment.translationSource else { return }
        let pieces = segment.sourcePieces + segment.deferredSource
        let directions = [firstSource] + segment.pendingTranslations.map(\.source)
        var first = segment
        first.deferredSource = []
        first.pendingTranslations = []
        first.hasAmbiguousSource = false
        first.isClosed = true
        guard pieces.count <= 4096, directions.count <= 32 else {
            emitUnassignedDirections(segment, isCatchUp: isCatchUp)
            return
        }
        var candidatesByLanguage: [Language: [Int]] = [:]
        var meaningfulPrefix = [0]
        var precedingLanguage: Language?
        for index in pieces.indices {
            meaningfulPrefix.append(meaningfulPrefix[index] + (meaningful(pieces[index].text) ? 1 : 0))
            guard let language = pieces[index].language else { continue }
            let boundary = hasSentenceBoundary(before: index, in: pieces)
            if precedingLanguage != language || boundary {
                candidatesByLanguage[language, default: []].append(index)
            }
            precedingLanguage = language
        }
        guard candidatesByLanguage.values.reduce(0, { $0 + $1.count }) <= 256 else {
            emitUnassignedDirections(segment, isCatchUp: isCatchUp)
            return
        }
        var cache: [String: [[Int]]] = [:]
        func match(_ direction: Int, after previous: Int) -> [[Int]] {
            if direction == directions.count {
                if let last = pieces[previous...].last(where: { $0.language != nil })?.language,
                    last != directions[direction - 1]
                {
                    return []
                }
                return [[]]
            }
            let key = "\(direction):\(previous)"
            if let cached = cache[key] { return cached }
            let candidates = candidatesByLanguage[directions[direction], default: []].filter { $0 > previous }
            var paths: [[Int]] = []
            for start in candidates {
                guard meaningfulPrefix[start] > meaningfulPrefix[previous] else { continue }
                if let last = pieces[previous..<start].last(where: { $0.language != nil })?.language,
                    last != directions[direction - 1]
                {
                    continue
                }
                let suffix = match(direction + 1, after: start)
                paths += suffix.prefix(2 - paths.count).map { [start] + $0 }
                if paths.count == 2 { break }
            }
            cache[key] = paths
            return paths
        }
        let matches = match(1, after: 0)
        guard matches.count == 1 else {
            // Untimed translation tokens cannot identify equally plausible
            // source partitions. Preserve the original caption and emit the
            // provider's final translations without inventing source text.
            emitUnassignedDirections(segment, isCatchUp: isCatchUp)
            return
        }
        let starts = [0] + matches[0] + [pieces.count]
        for index in directions.indices {
            var resolved = index == 0 ? first : Segment(id: nextSegmentID)
            if index != 0 { nextSegmentID += 1 }
            setOwnedSource(Array(pieces[starts[index]..<starts[index + 1]]), in: &resolved)
            resolved.translationSource = directions[index]
            resolved.language = directions[index]
            if index != 0 { resolved.translation = segment.pendingTranslations[index - 1].text }
            resolved.isClosed = true
            emitConfirmedOrRetract(resolved, isCatchUp: isCatchUp)
        }
    }

    private func emitUnassignedDirections(_ segment: Segment, isCatchUp: Bool) {
        var caption = segment
        foldDeferredSource(&caption)
        caption.pendingTranslations = []
        caption.hasAmbiguousSource = false
        caption.isClosed = true
        emitConfirmedOrRetract(caption, isCatchUp: isCatchUp)

        guard meaningful(caption.source) else { return }
        for translation in segment.pendingTranslations {
            var translated = Segment(id: nextSegmentID)
            nextSegmentID += 1
            translated.translation = translation.text
            translated.language = translation.source
            translated.translationSource = translation.source
            translated.isClosed = true
            emit(translated, isCatchUp: isCatchUp)
        }
    }

    private func hasSentenceBoundary(before index: Int, in pieces: [SourcePiece]) -> Bool {
        for piece in pieces[..<index].reversed() {
            if endsSentence(piece.text) { return true }
            if meaningful(piece.text) { return false }
        }
        return false
    }

    private func endsSentence(_ text: String) -> Bool {
        let closing = "\"'”’)]}"
        guard let last = text.last(where: { !$0.isWhitespace && !closing.contains($0) }) else { return false }
        return ".?!。！？".contains(last)
    }

    private func translationSource(_ token: [String: Any], fallback: Language?) -> Language? {
        let sourceCode = token["source_language"] as? String
        let targetCode = token["language"] as? String
        let source = configuredLanguage(sourceCode)
        let target = configuredLanguage(targetCode)
        if let sourceCode, !sourceCode.isEmpty, source == nil { return nil }
        if let targetCode, !targetCode.isEmpty, target == nil { return nil }
        if let source, let target { return source != target ? source : nil }
        if let source { return source }
        if let target { return config.languages.other(than: target) }
        // Missing metadata is useful only for formatting in an identified
        // translation; a new word must identify its source or target.
        return meaningful(token["text"] as? String ?? "") ? nil : fallback
    }

    private func configuredLanguage(_ code: String?) -> Language? {
        guard let code else { return nil }
        let base = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(
            String.init)
        return config.languages.language(code: base)
    }

    private func meaningful(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    @discardableResult
    private func emit(_ segment: Segment, isCatchUp: Bool, stableTranslation: String? = nil) -> Bool {
        // Wait for provider language evidence instead of letting an unknown
        // short transcript be guessed onto one of the conversation sides.
        guard segment.language != nil else { return false }
        onEvent(.segment(segment.event(isCatchUp: isCatchUp, stableTranslation: stableTranslation)))
        return true
    }

    private func emitConfirmedOrRetract(_ segment: Segment, isCatchUp: Bool) {
        var confirmed = segment
        if confirmed.language == nil {
            guard let language = confirmed.lastShownLanguage else { return }
            // A remembered preview direction can identify the view to clear,
            // but must not assign unclassified confirmed words to that side.
            confirmed.source = ""
            confirmed.translation = ""
            confirmed.translationSource = nil
            confirmed.language = language
        }
        emit(confirmed, isCatchUp: isCatchUp)
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

    private func closeOpenSegment(
        _ state: inout StreamState, notify: Bool = true, providerBoundary: Bool = false
    ) {
        guard var segment = state.open else { return }
        if !segment.pendingTranslations.isEmpty {
            state.open = nil
            if providerBoundary {
                closeAmbiguousDirections(segment, isCatchUp: state.isCatchUp)
            } else {
                if notify { emitUnassignedDirections(segment, isCatchUp: state.isCatchUp) }
            }
            return
        }
        foldDeferredSource(&segment)
        segment.isClosed = true
        state.open = nil
        if notify { emitConfirmedOrRetract(segment, isCatchUp: state.isCatchUp) }
    }
}

extension ProviderCredential {
    static let soniox =
        SonioxKeyProvider.shared == nil
        ? ProviderCredential(
            id: "soniox-api-key",
            name: "Soniox API key",
            help: "Create a key at console.soniox.com."
        )
        : ProviderCredential(
            id: "soniox-api-key",
            name: "Soniox API key (optional)",
            help:
                "Lively gets short-lived Soniox keys from its key service. For development, a key from console.soniox.com overrides it.",
            isOptional: true
        )
}

extension SpeechProvider {
    static let soniox = SpeechProvider(
        id: "soniox",
        name: "Soniox",
        summary:
            "Soniox stt-rt-v6 transcribes and translates both ways in one stream, for the lowest latency.",
        credentials: [.soniox],
        options: [],
        languages: Language.soniox,
        makePipeline: { settings in
            let key = settings.credential(.soniox)
            // A key entered in Settings overrides the broker.
            let credential: SonioxTranscriber.Credential =
                if key.isEmpty, let broker = SonioxKeyProvider.shared {
                    .broker(broker)
                } else {
                    .apiKey(key)
                }
            if settings.usesAutomaticLanguageDetection {
                let outgoing: TranslationService
                if let broker = BrokerTranslator.shared {
                    outgoing = FallbackTranslator(primary: broker, fallback: AppleTranslator())
                } else {
                    let key = settings.credential(.mistral)
                    outgoing = key.isEmpty ? AppleTranslator()
                        : MistralTranslator(apiKey: key, model: settings.translationModel)
                }
                return SpeechPipeline(
                    engine: AutomaticSonioxTranscriber(.init(
                        credential: credential, listenerLanguage: settings.speechListenerLanguage)),
                    translator: outgoing
                )
            }
            let cloud = SonioxTranscriber(.init(credential: credential, languages: settings.languages))
            guard SpeechProvider.onDevice.supports(settings.languages) else {
                return SpeechPipeline(engine: cloud, translator: nil)
            }
            // Keep on-device recognition available when the online service fails.
            let makeLocal: () -> SpeechEngine = {
                OfflineSpeechEngine(languages: settings.languages, script: settings.chineseScript,
                                    spokenLanguage: settings.offlineSpokenLanguage)
            }
            return SpeechPipeline(
                engine: HybridSpeechEngine(
                    local: makeLocal(), cloud: cloud, makeLocal: makeLocal
                ),
                translator: nil,
                fallbackTranslator: AppleTranslator()
            )
        }
    )
}
