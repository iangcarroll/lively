import Foundation

// These fakes isolate the real token parser from network and credentials.
protocol SocketDialect: AnyObject {}
struct SocketStream: Hashable {
    let id: Int
    let isCatchUp: Bool
}
enum SocketSignal {
    case none, ready, boundary
    case retry(String, throttled: Bool = false)
    case fail(String)
}
final class ResilientSocket {
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    init(dialect: any SocketDialect) {}
    func start() {}
    func prewarm() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func send(_ chunk: Data) {}
    func networkPathChanged() {}
}
final class SonioxKeyProvider {
    struct Key {
        let value: String
        let websocketURL: URL
        let region: String
    }
    final class Regions {
        func connectSucceeded(region: String) {}
        func connectFailed(region: String) {}
    }
    let regions = Regions()
    func startRefreshing() {}
    func stopRefreshing() {}
    func takeKey() async throws -> Key {
        .init(value: "unused", websocketURL: URL(string: "wss://example.invalid")!, region: "us")
    }
}
enum MicCapture { static let sampleRate: Double = 16000 }
extension URLSessionWebSocketTask.Message {
    static func json(_ value: [String: Any]) -> Self {
        .data(try! JSONSerialization.data(withJSONObject: value))
    }
    var jsonObject: [String: Any]? {
        switch self {
        case .data(let data): return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        case .string(let value):
            return try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        @unknown default: return nil
        }
    }
}

// INSERT_ACTUAL_LANGUAGE
// INSERT_ACTUAL_SPEECH_ENGINE
// INSERT_ACTUAL_SONIOX

@MainActor final class Capture {
    var events: [SpeechSegment] = []
    var resets = 0
    var order: [String] = []
    func attach(_ engine: SonioxTranscriber) {
        engine.onEvent = { [self] event in
            if case .segment(let segment) = event {
                events.append(segment)
                order.append("segment")
            }
            if case .sessionReset = event {
                resets += 1
                order.append("reset")
            }
        }
    }
    var last: SpeechSegment? { events.last }
    var latest: [Int: SpeechSegment] { events.reduce(into: [:]) { $0[$1.id] = $1 } }
}
@main struct Regression {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }
    static func token(
        _ text: String, _ language: String? = nil, final: Bool = true, status: String = "original",
        source: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = ["text": text, "is_final": final, "translation_status": status]
        if let language { value["language"] = language }
        if let source { value["source_language"] = source }
        return value
    }
    @MainActor static func engine(_ pair: LanguagePair = .init(first: .english, second: Language("ja"))) -> (
        SonioxTranscriber, Capture
    ) {
        let engine = SonioxTranscriber(.init(credential: .apiKey("test-only-unused"), languages: pair))
        let capture = Capture()
        capture.attach(engine)
        return (engine, capture)
    }
    @MainActor @discardableResult static func send(
        _ engine: SonioxTranscriber, _ tokens: [[String: Any]], stream: Int = 1, catchUp: Bool = false
    ) -> SocketSignal {
        engine.receive(.json(["tokens": tokens]), on: .init(id: stream, isCatchUp: catchUp))
    }
    @MainActor static func main() {
        let ja = Language("ja")
        let (switching, switches) = engine()
        send(
            switching,
            [
                token("Good morning.", "en"),
                token("おはよう。", "ja", status: "translation", source: "en"), token("<end>"),
                token("おはようございます。", "ja"),
            ])
        require(switches.latest.count == 2, "provider endpoints separate conversation turns")
        require(
            switches.latest.values.contains {
                $0.source == "Good morning." && $0.language == .english && $0.isClosed
            }, "English stays on its original side after Japanese begins")
        require(
            switches.last?.source == "おはようございます。" && switches.last?.language == ja,
            "new Japanese sentence owns only Japanese source")
        send(
            switching,
            [
                token("Good morning.", "en", status: "translation", source: "ja")
            ])
        require(
            switches.latest.values.contains {
                $0.source == "Good morning." && $0.translation == "おはよう。" && $0.language == .english
            }, "English translation stays with the provider-closed English source turn")
        require(
            switches.last?.translation == "Good morning." && switches.last?.language == ja,
            "Japanese translation retains the opposite direction")

        let (punctuation, punctuationCapture) = engine()
        send(punctuation, [token("Good morning", "en"), token(".", "ja")])
        require(
            punctuationCapture.last?.language == .english,
            "punctuation cannot relabel an entire spoken sentence")

        let (unknown, unknownCapture) = engine(.init(first: .english, second: Language("es")))
        send(unknown, [token("No"), token("No", "es", status: "translation", source: "en")])
        require(
            unknownCapture.last?.language == .english,
            "translation source metadata resolves an otherwise ambiguous source side")

        let (late, lateCapture) = engine()
        send(late, [token("Hello", "en")])
        let old = lateCapture.last!.id
        late.endTurn()
        require(
            lateCapture.last?.id == old && lateCapture.last?.isClosed == true,
            "a local timeout closes the displayed turn")
        send(late, [token("こんにちは", "ja", status: "translation", source: "en"), token("<fin>")])
        require(
            lateCapture.last?.id == old && lateCapture.last?.translation == "こんにちは",
            "translation after a local timeout updates the same provider turn")
        send(late, [token("How are you?", "en")])
        require(
            lateCapture.last?.id != old && lateCapture.last?.source == "How are you?",
            "same-language source after the provider boundary gets a new ID")
        send(late, [token("お元気ですか", "ja", status: "translation", source: "en")])
        require(
            lateCapture.latest[old]?.translation == "こんにちは"
                && lateCapture.last?.translation == "お元気ですか",
            "ordered translation after a provider boundary belongs to the next same-language turn")

        let (unknownClosed, unknownClosedCapture) = engine()
        send(unknownClosed, [token("No")])
        unknownClosed.endTurn()
        send(unknownClosed, [token("いいえ", "ja", final: false, status: "translation", source: "en")])
        require(
            unknownClosedCapture.last?.source == "No"
                && unknownClosedCapture.last?.language == .english
                && unknownClosedCapture.last?.stableTranslation.isEmpty == true,
            "provisional translation metadata can identify an unknown locally closed turn")
        let unknownID = unknownClosedCapture.last?.id
        send(unknownClosed, [token("いいえ", "ja", status: "translation", source: "en"), token("<fin>")])
        require(
            unknownClosedCapture.last?.id == unknownID
                && unknownClosedCapture.last?.stableTranslation == "いいえ",
            "final metadata resolves the held source without inventing another turn")

        let (outside, outsideCapture) = engine()
        send(outside, [token("Hello", "en"), token(" Starbucks", "fr", status: "none")])
        require(
            outsideCapture.last?.source == "Hello Starbucks",
            "an embedded third-language token is preserved in the original text")
        send(outside, [token("Bonjour", "fr", status: "translation", source: "en")])
        require(
            outsideCapture.latest.values.allSatisfy { !$0.translation.contains("Bonjour") },
            "out-of-pair target text cannot enter a configured translation side")
        let (foreignOnly, foreignCapture) = engine()
        send(foreignOnly, [token("Bonjour", "fr", status: "none"), token("<end>")])
        require(
            foreignCapture.events.isEmpty,
            "unsupported standalone speech is not guessed onto a configured side")

        let (mixed, mixedCapture) = engine(.init(first: .english, second: .chinese))
        send(mixed, [token("我们去", "zh"), token(" Starbucks", "en"), token("喝咖啡。", "zh")])
        require(
            mixedCapture.events.isEmpty,
            "conflicting word tags wait for sentence translation evidence")
        send(
            mixed,
            [
                token("Let's go to Starbucks for coffee.", "en", status: "translation", source: "zh"),
                token("<end>"),
            ])
        require(
            mixedCapture.latest.count == 1
                && mixedCapture.last?.source == "我们去 Starbucks喝咖啡。"
                && mixedCapture.last?.language == .chinese
                && mixedCapture.last?.translation == "Let's go to Starbucks for coffee.",
            "a code-switched phrase remains one complete translated Chinese turn")

        let (closeLanguages, closeCapture) = engine(.init(first: Language("no"), second: Language("da")))
        send(
            closeLanguages,
            [
                token("Jeg", "no"), token(" heter", "da"), token(" Ola", "no"),
                token("Jeg hedder Ola", "da", status: "translation", source: "no"), token("<end>"),
            ])
        require(
            closeCapture.latest.count == 1 && closeCapture.last?.source == "Jeg heter Ola"
                && closeCapture.last?.language == Language("no"),
            "a single close-language tag cannot remove a word or split its sentence")

        let (corrected, correctedCapture) = engine()
        send(corrected, [token("Hello", "ja")])
        let correctedID = correctedCapture.last?.id
        send(corrected, [token("こんにちは", "ja", status: "translation", source: "en")])
        require(
            correctedCapture.last?.id == correctedID
                && correctedCapture.last?.language == .english
                && correctedCapture.last?.stableTranslation == "こんにちは",
            "final translation metadata can correct tentative source tags before speech")
        send(corrected, [token(" Starbucks", "ja")])
        require(
            correctedCapture.last?.id == correctedID
                && correctedCapture.last?.source == "Hello"
                && correctedCapture.last?.language == .english
                && correctedCapture.last?.stableTranslation == "こんにちは",
            "a foreign word waits without changing an established speech direction")
        corrected.endTurn()
        send(corrected, [token("!", "en"), token("<fin>")])
        require(
            correctedCapture.last?.id == correctedID && correctedCapture.last?.source == "Hello Starbucks!"
                && correctedCapture.last?.language == .english
                && correctedCapture.last?.stableTranslation == "こんにちは"
                && correctedCapture.last?.isClosed == true,
            "the endpoint folds an embedded name back into the same ID and speech direction")

        let (orphan, orphanCapture) = engine()
        send(orphan, [token("Hello", "en"), token("<end>")])
        let closed = orphanCapture.last?.id
        send(orphan, [token("こんにちは", "ja", status: "translation", source: "en")])
        require(
            orphanCapture.last?.id == closed && orphanCapture.last?.translation.isEmpty == true,
            "an orphan translation after a provider boundary cannot retroactively guess an owner")

        let (configuration, _) = engine()
        let opening = configuration.openingMessages().first!.jsonObject!
        require(
            opening["enable_language_identification"] as? Bool == true,
            "online identification remains automatic")
        require(
            opening["language_hints"] as? [String] == ["en", "ja"],
            "both configured languages are supplied as hints")
        let translation = opening["translation"] as? [String: Any]
        require(
            translation?["type"] as? String == "two_way" && translation?["language_a"] as? String == "en"
                && translation?["language_b"] as? String == "ja",
            "the server translates both directions in one stream")
        require(
            opening["language_hints_strict"] == nil,
            "language hints do not silently become a forced-language mode")
        require(
            opening["sample_rate"] as? Int == 16000 && opening["num_channels"] as? Int == 1,
            "audio format stays mono16k")

        let (revised, revisedCapture) = engine()
        send(revised, [token("Hello", "ja", final: false)])
        let provisionalID = revisedCapture.last!.id
        require(
            revisedCapture.last?.language == ja && revisedCapture.last?.stableTranslation.isEmpty == true,
            "an early hypothesis cannot speak before stable translated text")
        send(revised, [token("Hello", "en", final: false)])
        require(
            revisedCapture.last?.id == provisionalID && revisedCapture.last?.language == .english,
            "revised provisional identification changes the same turn's side")
        send(revised, [token("Hello", "en"), token("こんにちは", "ja", status: "translation", source: "en")])
        require(
            revisedCapture.last?.source == "Hello" && revisedCapture.last?.stableTranslation == "こんにちは",
            "final tokens replace their provisional overlay exactly once")

        let (mixedPreview, mixedPreviewCapture) = engine()
        send(mixedPreview, [token("Hello", "en", final: false), token("こんにちは", "ja", final: false)])
        require(
            mixedPreviewCapture.events.isEmpty,
            "conflicting provisional word tags do not choose a conversation side")
        send(
            mixedPreview,
            [
                token("Bonjour", "fr", final: false, status: "none"),
                token("Hello", "en", final: false),
                token("こんにちは", "ja", final: false),
                token("Mixed original", "ja", final: false, status: "translation", source: "en"),
            ])
        require(
            mixedPreviewCapture.last?.source == "BonjourHelloこんにちは"
                && mixedPreviewCapture.last?.language == .english,
            "translation metadata assigns a complete multilingual preview without deleting words")

        let (unidentified, unidentifiedCapture) = engine()
        send(unidentified, [token("No")])
        require(
            unidentifiedCapture.events.isEmpty, "an unknown short source waits for provider language evidence"
        )
        send(unidentified, [token("いいえ", "ja", status: "translation", source: "en")])
        require(
            unidentifiedCapture.last?.source == "No" && unidentifiedCapture.last?.language == .english,
            "later translation metadata resolves a held source without guessing")

        let (overlay, overlayCapture) = engine()
        send(
            overlay, [token("Good morning", "en"), token("おはよう", "ja", status: "translation", source: "en")])
        send(overlay, [token("ございます", "ja", final: false, status: "translation", source: "en")])
        require(
            overlayCapture.last?.translation == "おはようございます"
                && overlayCapture.last?.stableTranslation == "おはよう",
            "only finalized translation prefix is available for speech")
        send(overlay, [token("！", "ja", final: false, status: "translation", source: "en")])
        require(
            overlayCapture.last?.translation == "おはよう！",
            "a provisional translation is replaced rather than accumulated")
        send(overlay, [token("ございます", "ja", status: "translation", source: "en")])
        require(
            overlayCapture.last?.translation == "おはようございます"
                && overlayCapture.last?.stableTranslation == "おはようございます",
            "a finalized translation is appended only once")
        send(overlay, [token("Wrong direction", "en", final: false, status: "translation", source: "ja")])
        require(
            overlayCapture.last?.language == .english
                && overlayCapture.last?.translation == "おはようございます"
                && overlayCapture.last?.stableTranslation == "おはようございます",
            "contradictory provisional metadata cannot move an existing spoken translation")
        send(overlay, [token("Wrong direction", "en", status: "translation", source: "ja")])
        require(
            overlayCapture.last?.translation == "おはようございます",
            "a contradictory known source is not relabeled to force a translation match")

        let (targetOnly, targetCapture) = engine()
        send(targetOnly, [token("OK"), token("了解", "ja", status: "translation")])
        require(
            targetCapture.last?.language == .english && targetCapture.last?.translation == "了解",
            "target metadata can resolve the other language of a two-way pair")
        send(
            targetOnly,
            [
                token("duplicate", "en", status: "translation", source: "en"),
                token("foreign", "ja", status: "translation", source: "fr"),
            ])
        require(
            targetCapture.last?.translation == "了解",
            "same-language and out-of-pair translation metadata is rejected")

        let (regional, regionalCapture) = engine()
        send(
            regional,
            [token("Hello", "EN_us"), token("こんにちは", "ja-JP", status: "translation", source: "en-US")])
        require(
            regionalCapture.last?.language == .english && regionalCapture.last?.translation == "こんにちは",
            "regional tags resolve to the configured pair")

        let (triple, tripleCapture) = engine()
        send(
            triple,
            [
                token("Hello", "en"), token("こんにちは", "ja", status: "translation", source: "en"),
                token("<end>"),
                token("おはよう", "ja"), token("Good morning", "en", status: "translation", source: "ja"),
                token("<end>"),
                token("Thanks", "en"), token("ありがとう", "ja", status: "translation", source: "en"),
                token("<end>"),
            ])
        require(
            tripleCapture.latest.count == 3 && tripleCapture.latest.values.allSatisfy(\.isClosed),
            "several provider endpoints in one response retain distinct closed turns")
        require(
            tripleCapture.latest.values.contains {
                $0.source == "Hello" && $0.translation == "こんにちは" && $0.language == .english
            }, "the earliest provider turn preserves its source and translation")
        require(
            tripleCapture.latest.values.contains {
                $0.source == "おはよう" && $0.translation == "Good morning" && $0.language == ja
            }, "the middle group preserves its source and translation")
        require(
            tripleCapture.latest.values.contains {
                $0.source == "Thanks" && $0.translation == "ありがとう" && $0.language == .english
            }, "the last group preserves its source and translation")

        let (streams, streamCapture) = engine()
        send(streams, [token("Live", "en")], stream: 10)
        let liveID = streamCapture.last!.id
        send(
            streams, [token("戻りました", "ja"), token("I returned", "en", status: "translation", source: "ja")],
            stream: 11, catchUp: true)
        let caughtID = streamCapture.last!.id
        require(
            liveID != caughtID && streamCapture.latest[caughtID]?.isCatchUp == true,
            "live and catch-up streams have separate segment identities")
        streams.endTurn()
        require(
            streamCapture.latest[liveID]?.isClosed == true
                && streamCapture.latest[caughtID]?.isClosed == false,
            "manual boundary closes only live streams")
        streams.sideStreamDidEnd(.init(id: 11, isCatchUp: true))
        require(
            streamCapture.latest[caughtID]?.isClosed == true
                && !streams.isMidUtterance(on: .init(id: 11, isCatchUp: true)),
            "ending catch-up closes and clears only that stream")
        streams.sessionDidReset(.init(id: 10, isCatchUp: false))
        require(streamCapture.resets == 1, "session replacement reports its boundary")
        send(streams, [token("Fresh", "en")], stream: 10)
        require(
            streamCapture.last?.id != liveID && streamCapture.last?.id != caughtID,
            "reset cannot reuse a previous turn identifier")

        for ending in ["reset", "stop", "side stream", "provider endpoint", "local timeout"] {
            let (preview, previewCapture) = engine()
            send(preview, [token("Hello", "en", final: false)])
            let previewID = previewCapture.last?.id
            switch ending {
            case "reset": preview.sessionDidReset(.init(id: 1, isCatchUp: false))
            case "stop": preview.stop()
            case "side stream": preview.sideStreamDidEnd(.init(id: 1, isCatchUp: true))
            case "provider endpoint": send(preview, [token("<end>")])
            default: preview.endTurn()
            }
            require(
                previewCapture.last?.id == previewID && previewCapture.last?.source.isEmpty == true
                    && previewCapture.last?.translation.isEmpty == true
                    && previewCapture.last?.stableTranslation.isEmpty == true
                    && previewCapture.last?.language == .english && previewCapture.last?.isClosed == true,
                "preview-only text is cleared and closed on \(ending)")
            if ending == "reset" {
                require(
                    Array(previewCapture.order.suffix(2)) == ["segment", "reset"],
                    "preview correction precedes session reset so replay cannot duplicate it")
            }
        }

        let (withdrawn, withdrawnCapture) = engine()
        send(withdrawn, [token("Hello", "en", final: false)])
        let withdrawnID = withdrawnCapture.last?.id
        send(withdrawn, [])
        require(
            withdrawnCapture.last?.id == withdrawnID && withdrawnCapture.last?.source.isEmpty == true
                && withdrawnCapture.last?.language == .english && withdrawnCapture.last?.isClosed == false,
            "an empty token list retracts its previous non-final hypothesis")
        send(withdrawn, [token("Hello", "en", final: false)])
        send(withdrawn, [token("Bonjour", "fr", final: false, status: "none")])
        require(
            withdrawnCapture.last?.id == withdrawnID && withdrawnCapture.last?.source.isEmpty == true,
            "replacement speech without a configured language retracts the earlier preview")
        send(withdrawn, [token("Hello", "en")])
        require(
            withdrawnCapture.last?.id == withdrawnID && withdrawnCapture.last?.source == "Hello",
            "confirmed words can restore a retracted preview without another segment ID")

        let (withdrawnTranslation, withdrawnTranslationCapture) = engine()
        send(withdrawnTranslation, [token("Hello", "en")])
        send(withdrawnTranslation, [token("こんにちは", "ja", final: false, status: "translation", source: "en")])
        send(withdrawnTranslation, [])
        require(
            withdrawnTranslationCapture.last?.source == "Hello"
                && withdrawnTranslationCapture.last?.translation.isEmpty == true,
            "withdrawn translation clears only the overlay and retains confirmed source")
        send(withdrawnTranslation, [token("こんにちは", "ja", status: "translation", source: "en")])
        send(withdrawnTranslation, [])
        require(
            withdrawnTranslationCapture.last?.source == "Hello"
                && withdrawnTranslationCapture.last?.stableTranslation == "こんにちは",
            "empty token frames cannot retract finalized source or speech")

        let (unclassified, unclassifiedCapture) = engine()
        send(unclassified, [token("No")])
        send(unclassified, [token("いいえ", "ja", final: false, status: "translation", source: "en")])
        let unclassifiedID = unclassifiedCapture.last?.id
        send(unclassified, [])
        require(
            unclassifiedCapture.last?.id == unclassifiedID
                && unclassifiedCapture.last?.source.isEmpty == true,
            "remembering a preview direction cannot classify held words after its metadata is withdrawn")
        send(unclassified, [token("いいえ", "ja", status: "translation", source: "en")])
        require(
            unclassifiedCapture.last?.id == unclassifiedID && unclassifiedCapture.last?.source == "No"
                && unclassifiedCapture.last?.stableTranslation == "いいえ",
            "held words remain available when final metadata resolves their source")

        let (remembered, rememberedCapture) = engine()
        send(remembered, [token("Hello", "en", final: false)])
        send(remembered, [token("こんにちは", "ja"), token("Hello", "en", final: false)])
        send(remembered, [token(" Hello", "en")])
        require(
            rememberedCapture.last?.source.isEmpty == true && rememberedCapture.last?.language == ja,
            "an empty correction remembers the last confirmed side that was actually shown")

        let (placeholder, placeholderCapture) = engine()
        send(placeholder, [token("Hello", "en")])
        let placeholderID = placeholderCapture.last?.id
        placeholder.endTurn()
        send(placeholder, [token("こんにちは", "ja", final: false)])
        send(placeholder, [])
        send(placeholder, [token("こんにちは", "ja", status: "translation", source: "en"), token("<fin>")])
        require(
            placeholderCapture.latest.count == 1 && placeholderCapture.last?.id == placeholderID
                && placeholderCapture.last?.source == "Hello"
                && placeholderCapture.last?.translation == "こんにちは",
            "an unconfirmed placeholder cannot displace the real turn awaiting its translation")

        let (heldOrder, heldOrderCapture) = engine()
        send(
            heldOrder,
            [
                token("No"), token("<end>"), token("こんにちは", "ja"),
                token("Hello", "en", status: "translation", source: "ja"), token("<end>"),
            ])
        require(
            heldOrderCapture.latest.count == 1 && heldOrderCapture.last?.source == "こんにちは",
            "an unidentified completed turn cannot be emitted later behind a newer provider turn")

        for reverse in [false, true] {
            for delayed in [false, true] {
                let (rapid, rapidCapture) = engine()
                let firstLanguage = reverse ? "ja" : "en"
                let secondLanguage = reverse ? "en" : "ja"
                let firstSource = reverse ? "駅はどこですか？" : "Where is the station?"
                let firstTranslation = reverse ? "Where is the station?" : "駅はどこですか？"
                let replySource = reverse ? "It's over there." : "あそこです。"
                let replyTranslation = reverse ? "あそこです。" : "It's over there."
                send(rapid, [token(firstSource, firstLanguage)])
                let firstID = rapidCapture.last?.id
                if delayed { send(rapid, [token(replySource, secondLanguage)]) }
                send(
                    rapid,
                    [token(firstTranslation, secondLanguage, status: "translation", source: firstLanguage)])
                if !delayed { send(rapid, [token(replySource, secondLanguage)]) }
                require(
                    rapidCapture.latest.count == 1 && rapidCapture.last?.id == firstID
                        && rapidCapture.last?.source == firstSource,
                    "an unconfirmed rapid reply is held outside the established source (\(reverse), \(delayed))"
                )
                send(
                    rapid,
                    [
                        token(
                            replyTranslation, firstLanguage, final: false, status: "translation",
                            source: secondLanguage)
                    ])
                require(
                    rapidCapture.latest.count == 1
                        && rapidCapture.last?.stableTranslation == firstTranslation,
                    "opposite provisional translation cannot confirm a direction boundary (\(reverse), \(delayed))"
                )
                send(
                    rapid,
                    [
                        token(replyTranslation, firstLanguage, status: "translation", source: secondLanguage),
                        token("<end>"),
                    ])
                let turns = rapidCapture.latest.values.sorted { $0.id < $1.id }
                require(
                    turns.map(\.source) == [firstSource, replySource] && turns.allSatisfy(\.isClosed),
                    "final translation metadata confirms two complete rapid turns (\(reverse), \(delayed))")
                require(
                    turns.map(\.translation) == [firstTranslation, replyTranslation]
                        && turns.map(\.language) == [Language(firstLanguage), Language(secondLanguage)],
                    "both rapid directions retain their own translations and outputs (\(reverse), \(delayed))"
                )
                require(
                    turns.allSatisfy { final in
                        rapidCapture.events.filter { $0.id == final.id && !$0.stableTranslation.isEmpty }
                            .allSatisfy { $0.language == final.language }
                    }, "a rapid boundary never relabels already stable speech (\(reverse), \(delayed))")
            }
        }

        let (continuedTranslation, continuedCapture) = engine()
        send(
            continuedTranslation,
            [
                token("Where is the station?", "en"),
                token("駅は", "ja", status: "translation", source: "en"),
            ])
        send(continuedTranslation, [token("あそこです。", "ja")])
        send(continuedTranslation, [token("どこですか？", "ja", status: "translation", source: "en")])
        send(
            continuedTranslation,
            [token("It's over there.", "en", status: "translation", source: "ja"), token("<end>")])
        require(
            continuedCapture.latest.values.sorted { $0.id < $1.id }.map(\.translation)
                == ["駅はどこですか？", "It's over there."],
            "remaining first-direction translation chunks do not consume the held reply")

        let (named, namedCapture) = engine()
        send(named, [token("Let's go to", "en"), token("行きましょう", "ja", status: "translation", source: "en")])
        let namedID = namedCapture.last?.id
        send(named, [token(" Starbucks", "ja")])
        send(named, [token(" tomorrow.", "en")])
        require(
            namedCapture.latest.count == 1 && namedCapture.last?.id == namedID
                && namedCapture.last?.source == "Let's go to Starbucks tomorrow.",
            "same-source continuation folds an embedded other-language name back in order")
        send(named, [token("明日スターバックスに", "ja", status: "translation", source: "en"), token("<end>")])
        require(
            namedCapture.last?.id == namedID && namedCapture.last?.language == .english
                && namedCapture.last?.source == "Let's go to Starbucks tomorrow.",
            "an embedded name does not create another translated turn")

        let (nameThenReply, nameReplyCapture) = engine()
        send(
            nameThenReply,
            [token("Let's go to", "en"), token("行きましょう", "ja", status: "translation", source: "en")])
        send(
            nameThenReply,
            [
                token(" Starbucks", "ja"), token(" tomorrow.", "en"),
            ])
        send(
            nameThenReply,
            [token("はい。", "ja"), token("Yes.", "en", status: "translation", source: "ja"), token("<end>")])
        let nameTurns = nameReplyCapture.latest.values.sorted { $0.id < $1.id }
        require(
            nameTurns.map(\.source).joined() == "Let's go to Starbucks tomorrow.はい。",
            "ambiguous ownership preserves the name and every original in order")
        require(
            nameTurns.first?.language == .english
                && nameTurns.contains {
                    $0.language == ja && $0.translation == "Yes." && $0.stableTranslation == "Yes."
                }, "name ownership cannot discard or reroute confirmed speech")

        let (trailingName, trailingNameCapture) = engine()
        send(
            trailingName,
            [token("Let's go to", "en"), token("行きましょう", "ja", status: "translation", source: "en")])
        send(
            trailingName,
            [
                token(" Starbucks", "ja"),
                token("スターバックスに", "ja", status: "translation", source: "en"), token("<end>"),
            ])
        require(
            trailingNameCapture.latest.count == 1
                && trailingNameCapture.last?.source == "Let's go to Starbucks"
                && trailingNameCapture.last?.translation == "行きましょうスターバックスに",
            "same-direction translation plus endpoint preserves a trailing foreign name")

        let (thirdName, thirdNameCapture) = engine()
        send(
            thirdName,
            [token("Let's go to", "en"), token("行きましょう", "ja", status: "translation", source: "en")])
        send(thirdName, [token(" Le Café", "fr", status: "none"), token("<end>")])
        require(
            thirdNameCapture.latest.count == 1 && thirdNameCapture.last?.source == "Let's go to Le Café"
                && thirdNameCapture.last?.language == .english,
            "a third-language name after translation remains in the same complete source")

        let (rapidPreview, rapidPreviewCapture) = engine()
        send(rapidPreview, [token("Hello", "en"), token("こんにちは", "ja", status: "translation", source: "en")])
        send(rapidPreview, [token("あそこです。", "ja", final: false)])
        send(rapidPreview, [])
        send(rapidPreview, [token("<end>")])
        require(
            rapidPreviewCapture.latest.count == 1 && rapidPreviewCapture.last?.source == "Hello"
                && rapidPreviewCapture.last?.translation == "こんにちは",
            "a withdrawn possible reply cannot donate provisional words to the prior source")

        let (localRapid, localRapidCapture) = engine()
        send(localRapid, [token("Where?", "en"), token("どこ？", "ja", status: "translation", source: "en")])
        let localRapidID = localRapidCapture.last?.id
        localRapid.endTurn()
        send(
            localRapid,
            [token("あそこ。", "ja"), token("There.", "en", status: "translation", source: "ja"), token("<fin>")])
        require(
            localRapidCapture.latest.count == 2
                && localRapidCapture.latest.values.contains { $0.id == localRapidID && $0.source == "Where?" }
                && localRapidCapture.last?.source == "あそこ。"
                && localRapidCapture.last?.translation == "There.",
            "a confirmed rapid reply after local close preserves the original ID and uses a new reply ID")

        for queued in [false, true] {
            let (manyRapid, manyRapidCapture) = engine()
            let turns = [
                ("Where?", "en", "どこ？", "ja"), ("あそこ。", "ja", "There.", "en"),
                ("Thanks.", "en", "ありがとう。", "ja"), ("どういたしまして。", "ja", "You're welcome.", "en"),
            ]
            if queued { send(manyRapid, turns.map { token($0.0, $0.1) }) }
            for (source, language, translation, target) in turns {
                var tokens = [token(translation, target, status: "translation", source: language)]
                if !queued { tokens.insert(token(source, language), at: 0) }
                send(manyRapid, tokens)
            }
            send(manyRapid, [token("<end>")])
            let actual = manyRapidCapture.latest.values.sorted { $0.id < $1.id }
            require(
                actual.map(\.source) == turns.map(\.0) && actual.allSatisfy(\.isClosed),
                "several rapid directions preserve ordered complete source, queued=\(queued)")
            require(
                actual.map(\.translation) == turns.map(\.2),
                "several rapid directions never merge or duplicate translations, queued=\(queued)")
        }

        for reverse in [false, true] {
            let originalLanguage = reverse ? "ja" : "en"
            let replyLanguage = reverse ? "en" : "ja"
            for label: String? in [originalLanguage, nil] {
                let (mistagged, mistaggedCapture) = engine()
                let question = reverse ? "駅はどこですか？" : "Where is the station?"
                let translatedQuestion = reverse ? "Where is the station?" : "駅はどこですか？"
                let reply = reverse ? "Yes" : "はい"
                let translatedReply = reverse ? "はい" : "Yes"
                send(
                    mistagged,
                    [
                        token(question, originalLanguage),
                        token(
                            translatedQuestion, replyLanguage, status: "translation", source: originalLanguage
                        ),
                    ])
                let establishedID = mistaggedCapture.last?.id
                send(mistagged, [token(reply, label)])
                send(
                    mistagged,
                    [
                        token(
                            translatedReply, originalLanguage, status: "translation", source: replyLanguage),
                        token("<end>"),
                    ])
                let actual = mistaggedCapture.latest.values.sorted { $0.id < $1.id }
                require(
                    actual.map(\.source).joined() == question + reply
                        && actual.map(\.language) == [Language(originalLanguage), Language(replyLanguage)],
                    "final metadata preserves originals and honest direction with wrong or missing tags (\(reverse), \(label ?? "missing"))"
                )
                require(
                    actual.first?.id == establishedID
                        && actual.map(\.translation) == [translatedQuestion, translatedReply],
                    "a corrected reply gets a new ID without changing established speech (\(reverse), \(label ?? "missing"))"
                )
            }
        }

        let (formatting, formattingCapture) = engine()
        send(
            formatting,
            [
                token("Where?", "en"), token("どこ？", "ja", status: "translation", source: "en"),
                token("はい", "ja"),
            ])
        send(formatting, [token(".", "en", status: "translation", source: "ja")])
        require(
            formattingCapture.latest.count == 1,
            "formatting-only translation cannot establish a new speech direction")
        send(formatting, [token("Yes", "en", status: "translation", source: "ja"), token("<end>")])
        require(
            formattingCapture.latest.values.sorted { $0.id < $1.id }.map(\.translation) == ["どこ？", "Yes"],
            "meaningful translation confirms the held reply after ignored formatting")

        for punctuation in 0..<16 {
            let (unpunctuated, unpunctuatedCapture) = engine()
            let original = ["One", "二", "Three", "四"]
            let languages = ["en", "ja", "en", "ja"]
            let translated = ["一", "Two", "三", "Four"]
            var sources: [[String: Any]] = []
            for index in original.indices {
                sources.append(
                    token(
                        original[index] + (punctuation & (1 << index) != 0 ? "." : ""),
                        languages[index]))
            }
            send(unpunctuated, sources)
            for index in original.indices {
                send(
                    unpunctuated,
                    [
                        token(
                            translated[index], languages[index] == "en" ? "ja" : "en",
                            status: "translation", source: languages[index])
                    ])
                if index == 0 {
                    require(
                        unpunctuatedCapture.last?.source == original[0] + (punctuation & 1 != 0 ? "." : "")
                            && unpunctuatedCapture.latest.count == 1,
                        "first stable direction holds every later source owner, punctuation=\(punctuation)")
                }
            }
            send(unpunctuated, [token("<end>")])
            let actual = unpunctuatedCapture.latest.values.sorted { $0.id < $1.id }
            require(
                actual.map(\.source)
                    == original.indices.map {
                        original[$0] + (punctuation & (1 << $0) != 0 ? "." : "")
                    },
                "queued originals retain all four owners despite missing or mixed sentence punctuation (\(punctuation))"
            )
            require(
                actual.map(\.translation) == translated && actual.allSatisfy(\.isClosed),
                "unique queued direction evidence releases complete translations in order (\(punctuation))")
        }

        let (ambiguous, ambiguousCapture) = engine()
        send(ambiguous, [token("One", "en"), token("二", "ja"), token("Three", "en"), token("四", "ja")])
        send(
            ambiguous,
            [
                token("一", "ja", status: "translation", source: "en"),
                token("Reply", "en", status: "translation", source: "ja"),
                token("!", status: "translation"), token("<end>"),
            ])
        require(
            ambiguousCapture.latest.values.contains { $0.source == "One二Three四" }
                && ambiguousCapture.events.filter { $0.id == 0 && !$0.stableTranslation.isEmpty }.allSatisfy {
                    $0.language == .english
                },
            "equally plausible untimed partitions preserve all source and established speech direction"
        )
        require(
            ambiguousCapture.latest.count == 2 && ambiguousCapture.last?.source.isEmpty == true
                && ambiguousCapture.last?.language == ja && ambiguousCapture.last?.translation == "Reply!"
                && ambiguousCapture.last?.stableTranslation == "Reply!"
                && ambiguousCapture.last?.isClosed == true,
            "unambiguous final translation remains routable without guessed original-word ownership")
        require(
            (ambiguousCapture.last?.language).map {
                LanguagePair(first: .english, second: ja).other(than: $0)
            }
                == .english,
            "the translation-only Japanese source targets the English listener")

        let (lateAmbiguous, lateAmbiguousCapture) = engine()
        send(
            lateAmbiguous, [token("One", "en"), token("二", "ja"), token("Three", "en"), token("四", "ja")],
            stream: 7, catchUp: true)
        send(
            lateAmbiguous,
            [
                token("一", "ja", status: "translation", source: "en"),
                token("Reply", "en", status: "translation", source: "ja"), token("<end>"),
            ],
            stream: 7, catchUp: true)
        require(
            lateAmbiguousCapture.last?.source.isEmpty == true && lateAmbiguousCapture.last?.isCatchUp == true
                && lateAmbiguousCapture.last?.stableTranslation == "Reply",
            "translation-only catch-up preserves its real stream provenance and final speech")

        // Interleaved originals can look like a name until final translation
        // evidence confirms the reply. Exercise the incremental fold path,
        // independently of the queued-original partition cases above.
        for reverse in [false, true] {
            let firstLanguage = reverse ? "ja" : "en"
            let replyLanguage = reverse ? "en" : "ja"
            let question = reverse ? "これですか" : "Is it this one"
            let reply = reverse ? "Yes" : "はい"
            let continuation = reverse ? " 了解です" : " OK thanks"
            let translatedQuestion = reverse ? "Is it this one" : "これですか"
            let translatedReply = reverse ? "はい" : "Yes"
            for punctuation in 0..<8 {
                let labels: [String?] = [replyLanguage, firstLanguage, nil]
                for label in labels {
                    let (incremental, captured) = engine()
                    let first = question + (punctuation & 1 == 0 ? "" : ".")
                    let second = reply + (punctuation & 2 == 0 ? "" : ".")
                    let third = continuation + (punctuation & 4 == 0 ? "" : ".")
                    send(
                        incremental,
                        [
                            token(first, firstLanguage),
                            token(
                                translatedQuestion, replyLanguage, status: "translation",
                                source: firstLanguage),
                        ])
                    let originalID = captured.last?.id
                    send(incremental, [token(second, label)])
                    send(incremental, [token(third, firstLanguage)])
                    send(
                        incremental,
                        [token(translatedReply, firstLanguage, status: "translation", source: replyLanguage)])
                    send(incremental, [token("<end>")])
                    let final = captured.latest.values.sorted { $0.id < $1.id }
                    let description =
                        "reverse=\(reverse), punctuation=\(punctuation), tag=\(label ?? "missing")"
                    require(
                        final.map(\.source).joined() == first + second + third,
                        "incremental fold preserves every original word: \(description)")
                    require(
                        final.contains {
                            $0.language == Language(replyLanguage)
                                && $0.translation == translatedReply
                                && $0.stableTranslation == translatedReply
                        },
                        "incremental fold retains the confirmed reply and its speech direction: \(description)"
                    )
                    require(
                        final.first?.id == originalID && final.first?.language == Language(firstLanguage)
                            && final.first?.translation == translatedQuestion,
                        "incremental reply cannot relabel or replace the established speech: \(description)")
                }
            }
        }

        let (claimedName, claimedNameCapture) = engine()
        send(
            claimedName,
            [
                token("Let's go to", "en"),
                token("行きましょう", "ja", status: "translation", source: "en"),
            ])
        send(claimedName, [token(" Starbucks", "ja"), token(" tomorrow", "en")])
        send(claimedName, [token("明日スターバックスに", "ja", status: "translation", source: "en")])
        send(
            claimedName, [token("Invented reply", "en", status: "translation", source: "ja"), token("<end>")])
        let claimedTurns = claimedNameCapture.latest.values.sorted { $0.id < $1.id }
        require(
            claimedTurns.map(\.source).joined() == "Let's go to Starbucks tomorrow",
            "unreceipted folded originals remain lossless after another translation chunk")
        require(
            claimedTurns.first?.language == .english
                && claimedTurns.contains {
                    $0.language == ja && $0.translation == "Invented reply"
                        && $0.stableTranslation == "Invented reply"
                }, "identical wire shapes preserve final opposite speech instead of assuming it is false")

        // Different token boundaries must preserve the same final directions.
        func pieces(_ text: String, width: Int) -> [String] {
            guard width > 0 else { return [text] }
            let value = Array(text)
            return stride(from: 0, to: value.count, by: width).map {
                String(value[$0..<min(value.count, $0 + width)])
            }
        }
        let scenarios: [(parts: Int, split: Bool, third: Bool, width: Int, label: Int, punct: Bool)] = [
            (2, false, true, 0, 0, false), (3, false, false, 0, 0, false),
            (2, true, false, 0, 0, false), (3, true, true, 0, 0, false),
            (2, true, true, 1, 0, false), (3, false, true, 2, 0, false),
            (2, false, true, 1, 1, false), (3, true, true, 2, 2, false),
            (2, true, false, 1, 1, true), (3, false, false, 2, 2, true),
            (2, false, true, 2, 0, true), (3, true, true, 1, 0, true),
        ]
        for reverse in [false, true] {
            let a = reverse ? "ja" : "en"
            let b = reverse ? "en" : "ja"
            for test in scenarios {
                let (subject, captured) = engine()
                let q = (reverse ? "これですか" : "Is it this one") + (test.punct ? "?" : "")
                let r = (reverse ? "Yes" : "はい") + (test.punct ? "." : "")
                let continuation =
                    reverse
                    ? (test.parts == 2 ? [" 了解", "です"] : [" 了", "解", "です"])
                    : (test.parts == 2 ? [" OK", " thanks"] : [" O", "K", " thanks"])
                let tq = reverse ? "Is it this one" : "これですか"
                let tr = reverse ? "はい" : "Yes"
                let tc = reverse ? "OK, thank you" : "了解、ありがとう"
                let label: String? = test.label == 0 ? b : (test.label == 1 ? a : nil)
                func original(_ text: String, _ language: String?) {
                    send(subject, pieces(text, width: test.width).map { token($0, language) })
                }
                func translated(_ text: String, _ source: String) {
                    let target = source == a ? b : a
                    for part in pieces(text, width: test.width) {
                        send(subject, [token(part, target, status: "translation", source: source)])
                    }
                }
                original(q, a)
                translated(test.split ? String(tq.prefix(1)) : tq, a)
                let establishedID = captured.last?.id
                original(r, label)
                for part in continuation { original(part, a) }
                if test.split { translated(String(tq.dropFirst()), a) }
                translated(tr, b)
                if test.third { translated(tc, a) }
                send(subject, [token("<end>")])
                let actual = captured.latest.values.sorted { $0.id < $1.id }
                let expectedText = [tq, tr] + (test.third ? [tc] : [])
                let expectedLanguages = [Language(a), Language(b)] + (test.third ? [Language(a)] : [])
                let info =
                    "reverse=\(reverse),parts=\(test.parts),split=\(test.split),third=\(test.third),width=\(test.width),label=\(test.label),punct=\(test.punct)"
                require(
                    actual.map(\.source).joined() == q + r + continuation.joined(),
                    "token boundaries cannot lose, fabricate or reorder originals: \(info)")
                require(
                    actual.map(\.translation) == expectedText
                        && actual.map(\.stableTranslation) == expectedText,
                    "all final translation chunks survive the interleaved fold: \(info)")
                require(
                    actual.map(\.language) == expectedLanguages && actual.allSatisfy(\.isClosed)
                        && actual.first?.id == establishedID,
                    "all final directions retain established IDs and languages: \(info)")
                require(
                    captured.events.filter { $0.id == establishedID && !$0.stableTranslation.isEmpty }
                        .allSatisfy { $0.language == Language(a) },
                    "fold resolution cannot reroute established speech: \(info)")
            }
        }

        let (fourIncremental, fourCapture) = engine()
        let exchange = [
            ("Question", "en", "質問", "ja"), ("はい", "ja", "Yes", "en"),
            (" OK thanks", "en", "了解", "ja"), ("どうも", "ja", "Welcome", "en"),
        ]
        send(
            fourIncremental,
            [token(exchange[0].0, "en"), token(exchange[0].2, "ja", status: "translation", source: "en")])
        for turn in exchange.dropFirst() { send(fourIncremental, [token(turn.0, turn.1)]) }
        for turn in exchange.dropFirst() {
            send(fourIncremental, [token(turn.2, turn.3, status: "translation", source: turn.1)])
        }
        send(fourIncremental, [token("<end>")])
        let fourRows = fourCapture.latest.values.sorted { $0.id < $1.id }
        require(
            fourRows.map(\.source) == exchange.map(\.0),
            "a real fold retains four incremental owners until their final evidence arrives")
        require(
            fourRows.map(\.translation) == exchange.map(\.2)
                && fourRows.map(\.language) == exchange.map { Language($0.1) },
            "four incremental final directions retain exact translated output and language")
        for reverse in [false, true] {
            let (live, liveCapture) = engine()
            let a = reverse ? "ja" : "en"
            let b = reverse ? "en" : "ja"
            let first = reverse ? ["これ", "ですか？"] : ["Where is", " the station?"]
            let tq = reverse ? ["Where is", " the station?"] : ["これ", "ですか？"]
            let second = reverse ? ["Over", " there."] : ["あそこ", "です。"]
            let tr = reverse ? ["あそこ", "です。"] : ["It's", " over there."]
            for index in 0..<2 {
                send(live, [token(first[index], a), token(tq[index], b, status: "translation", source: a)])
            }
            let firstID = liveCapture.last?.id
            send(live, [token(second[0], b), token(tr[0], a, status: "translation", source: b)])
            require(
                liveCapture.latest.count == 2 && liveCapture.last?.language == Language(b)
                    && liveCapture.last?.source == second[0] && liveCapture.last?.isClosed == false,
                "clean deferred reply appears before an endpoint, reverse=\(reverse)")
            send(live, [token(second[1], b), token(tr[1], a, status: "translation", source: b)])
            require(
                liveCapture.last?.source == second.joined()
                    && liveCapture.last?.stableTranslation == tr.joined(),
                "complete reply speech is ready before an endpoint, reverse=\(reverse)")
            live.sessionDidReset(.init(id: 1, isCatchUp: false))
            require(
                liveCapture.latest[firstID ?? -1]?.source == first.joined()
                    && liveCapture.last?.source == second.joined(),
                "reset cannot merge a clean reply into the previous caption, reverse=\(reverse)")
        }
        let (unbacked, unbackedCapture) = engine()
        send(unbacked, [token("Hello", "en", status: "translation", source: "ja"), token("<end>")])
        require(
            unbackedCapture.events.isEmpty,
            "translation cannot borrow original provenance from a source-less epoch")
        send(unbacked, [token("Hello", "en")], stream: 1)
        send(
            unbacked, [token("Reply", "en", status: "translation", source: "ja"), token("<end>")], stream: 2)
        require(
            unbackedCapture.latest.count == 1 && unbackedCapture.last?.language == .english
                && unbackedCapture.last?.stableTranslation.isEmpty == true,
            "translation cannot borrow original provenance from another stream")

        print("Soniox language regressions: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
