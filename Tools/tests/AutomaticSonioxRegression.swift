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
// INSERT_ACTUAL_MANUAL
// INSERT_ACTUAL_AUTOMATIC
// INSERT_ACTUAL_SENTENCE_HELPER
// INSERT_ACTUAL_FILLER

@main
struct AutomaticSonioxRegression {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }
    final class Harness {
        let engine: AutomaticSonioxTranscriber
        var events: [AutoSpeechSegment] = []
        var latest: [Int: AutoSpeechSegment] = [:]
        init(listener: Language = .english) {
            engine = AutomaticSonioxTranscriber(
                .init(credential: .apiKey("unused"), listenerLanguage: listener))
            engine.onEvent = { [weak self] event in
                guard case .autoSegment(let segment) = event else { return }
                self?.events.append(segment)
                self?.latest[segment.id] = segment
            }
        }
        func send(_ tokens: [[String: Any]], stream: Int = 0, catchUp: Bool = false) {
            _ = engine.receive(.json(["tokens": tokens]), on: .init(id: stream, isCatchUp: catchUp))
        }
        var visible: [AutoSpeechSegment] {
            latest.values.filter { !$0.source.isEmpty || !$0.translation.isEmpty }.sorted { $0.id < $1.id }
        }
    }
    static func source(_ text: String, _ language: String?, final: Bool = true, status: String = "none")
        -> [String: Any]
    {
        var value: [String: Any] = ["text": text, "is_final": final, "translation_status": status]
        value["language"] = language
        return value
    }
    static func translated(_ text: String, _ language: String?, final: Bool = true, target: String = "en")
        -> [String: Any]
    {
        var value: [String: Any] = [
            "text": text, "is_final": final, "translation_status": "translation", "language": target,
        ]
        value["source_language"] = language
        return value
    }
    static let end: [String: Any] = ["text": "<end>", "is_final": true]
    static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func main() throws {
        let config = Harness().engine.openingMessages()[0].jsonObject!
        let translation = config["translation"] as! [String: String]
        expect(translation == ["type": "one_way", "target_language": "en"], "one-way to listener")
        expect(
            config["language_hints"] == nil && config["language_hints_strict"] == nil,
            "unrestricted language ID")
        expect(config["enable_language_identification"] as? Bool == true, "language ID enabled")
        expect(
            config["sample_rate"] as? Int == 16000 && config["num_channels"] as? Int == 1,
            "real microphone format")
        let replay = Harness()
        let lines = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(
            separator: "\n")
        for line in lines {
            _ = replay.engine.receive(.string(String(line)), on: .init(id: 0, isCatchUp: false))
        }
        let real = replay.visible
        expect(real.count == 4, "real one-way fixture four source turns")
        expect(
            real.map { trim($0.source) } == [
                "Thank you very much.", "ありがとうございます。", "Thank you very much.", "ありがとうございます。",
            ], "real original text exact")
        expect(
            real.map(\.language) == [.english, Language("ja"), .english, Language("ja")],
            "real unrestricted directions")
        expect(
            real.map(\.target) == [nil, .english, nil, .english], "English has no invented outgoing target")
        expect(
            real.map { trim($0.stableTranslation) } == [
                "", "Thank you very much.", "", "Thank you very much.",
            ], "only foreign incoming native translations")
        expect(
            real.allSatisfy { $0.isClosed && $0.isSourceFinal && $0.languageIsFinal },
            "provider-final evidence on real fixture")

        let english = Harness()
        english.send([source("Where is the station?", "en")])
        expect(
            english.visible.first?.source == "Where is the station?", "English visible before partner known")
        expect(
            english.visible.first?.target == nil && english.visible.first?.languageIsFinal == true
                && english.visible.first?.isPartnerEvidence == false,
            "coherent final prefix has no invented target or partner evidence")
        english.engine.endTurn()
        expect(
            english.visible.first?.isClosed == true && english.visible.first?.isSourceFinal == false,
            "local timeout is not provider completion")
        english.send([end])
        expect(english.visible.first?.isSourceFinal == true, "provider endpoint completes same ID")
        expect(english.visible.first?.target == nil, "English remains pending without discovered target")

        for code in ["es", "fr", "ko", "pt-BR"] {
            let h = Harness()
            h.send([
                source("Original \(code)", code, status: "original"), translated("Incoming \(code)", code),
            ])
            expect(
                h.visible.first?.stableTranslation == "Incoming \(code)",
                "foreign stable before endpoint \(code)")
            expect(
                h.visible.first?.languageIsFinal == true && h.visible.first?.isPartnerEvidence == false,
                "coherent prefix has no unclosed partner evidence \(code)")
            h.send([end])
            expect(
                h.visible.first?.language
                    == Language(code.lowercased().split(separator: "-").first.map(String.init)!),
                "normalizes regional tag \(code)")
            expect(
                h.visible.first?.languageIsFinal == true && h.visible.first?.isPartnerEvidence == true
                    && h.visible.first?.target == .english,
                "coherent final metadata confirms foreign \(code)")
        }
        let prefix = Harness()
        prefix.send([
            source("Where is it?", "en"), source("あそこです。", "ja", status: "original"),
            translated("It is there.", "ja"), end,
        ])
        expect(
            prefix.visible.map(\.source) == ["Where is it?", "あそこです。"],
            "foreign source never steals English-first prefix")
        expect(prefix.visible.map(\.target) == [nil, .english], "prefix directions independent")

        let volatile = Harness()
        volatile.send([
            source("wrong", "es", final: false, status: "original"),
            translated("wrong preview", "es", final: false),
        ])
        expect(
            volatile.visible.first?.stableTranslation == ""
                && volatile.visible.first?.languageIsFinal == false,
            "volatile never speech or partner evidence")
        volatile.send([])
        expect(volatile.visible.isEmpty, "empty frame retracts withdrawn hypothesis")
        expect(
            volatile.events.last?.source == "" && volatile.events.last?.translation == ""
                && volatile.events.last?.isClosed == true, "explicit ghost removal event")
        volatile.send([source("Hola", "es", final: false, status: "original")])
        volatile.engine.sessionDidReset(.init(id: 0, isCatchUp: false))
        expect(volatile.visible.isEmpty, "reset retracts only-preview source")

        let catchup = Harness()
        catchup.send(
            [source("Bonjour", "fr", status: "original"), translated("Hello", "fr"), end], stream: 4,
            catchUp: true)
        expect(
            catchup.visible.first?.isCatchUp == true && catchup.visible.first?.languageIsFinal == true
                && catchup.visible.first?.isSourceFinal == true
                && catchup.visible.first?.isPartnerEvidence == false,
            "catchup cannot switch partner")
        catchup.send([source("Hello", "en"), end], stream: 5)
        expect(
            catchup.visible.count == 2 && Set(catchup.visible.map(\.id)).count == 2,
            "streams keep global distinct IDs")

        let contradiction = Harness()
        contradiction.send([source("こんにちは", "ja", status: "original"), translated("Hello", "es"), end])
        expect(
            contradiction.visible.contains { $0.source == "こんにちは" && !$0.isPartnerEvidence },
            "contradictory native metadata cannot confirm Japanese")
        expect(
            contradiction.visible.contains {
                $0.stableTranslation == "Hello" && $0.target == .english && !$0.languageIsFinal
            }, "real translation retained without guessing partner")
        let missing = Harness()
        missing.send([source("こんにちは", nil, status: "original"), translated("Hello", nil), end])
        expect(
            missing.visible.allSatisfy { $0.language == nil && !$0.languageIsFinal },
            "target alone never invents source language")
        expect(
            missing.visible.contains { $0.stableTranslation == "Hello" && $0.target == .english },
            "unknown-source native output still has explicit headphone target")
        let identity = Harness()
        identity.send([source("Hello", "en"), translated("Hello", "en"), end])
        expect(
            identity.visible.count == 1 && identity.visible[0].translation.isEmpty,
            "identity translation never echoes user")
        let noOriginal = Harness()
        noOriginal.send([translated("Unsupported", "ja"), end])
        expect(noOriginal.visible.isEmpty, "translation with no original provenance suppressed")
        let fallback = Harness()
        fallback.send([source("Bonjour", "fr", status: "original")])
        expect(fallback.visible.first?.target == nil, "raw foreign source-only while native pending")
        fallback.send([end])
        expect(
            fallback.visible.first?.target == .english && fallback.visible.first?.languageIsFinal == true
                && fallback.visible.first?.isPartnerEvidence == false,
            "explicit fallback without fabricated partner evidence")

        let listener = Harness(listener: Language("ja"))
        let target = listener.engine.openingMessages()[0].jsonObject!["translation"] as! [String: String]
        expect(target["target_language"] == "ja", "listener independent of English default")
        listener.send([
            source("Hello", "en", status: "original"), translated("こんにちは", "en", target: "ja"), end,
        ])
        expect(
            listener.visible.first?.language == .english && listener.visible.first?.target == Language("ja"),
            "non-English listener routing")
        for size in [1, 2, 100] {
            func chunks(_ text: String) -> [String] {
                let chars = Array(text)
                return stride(from: 0, to: chars.count, by: size).map {
                    String(chars[$0..<min($0 + size, chars.count)])
                }
            }
            let mixed = Harness()
            for value in chunks("We will meet ") { mixed.send([source(value, "en")]) }
            for value in chunks("田中") { mixed.send([source(value, "ja", status: "original")]) }
            for value in chunks(" at the station.") { mixed.send([source(value, "en")]) }
            mixed.send([end])
            expect(
                mixed.visible.count == 1 && mixed.visible[0].source == "We will meet 田中 at the station.",
                "embedded name folded without text loss size\(size)")
            expect(
                mixed.visible[0].target == nil && mixed.visible[0].language == .english,
                "embedded name retains listener role without foreign discovery size\(size)")
            let chinese = Harness()
            for value in chunks("我们去") { chinese.send([source(value, "zh", status: "original")]) }
            for value in chunks(" Starbucks ") { chinese.send([source(value, "en")]) }
            for value in chunks("喝咖啡。") { chinese.send([source(value, "zh", status: "original")]) }
            for value in chunks("Let us have coffee at Starbucks.") {
                chinese.send([translated(value, "zh")])
            }
            chinese.send([end])
            expect(
                chinese.visible.map(\.source).joined() == "我们去 Starbucks 喝咖啡。",
                "foreign embedded English keeps full original size\(size)")
            expect(
                chinese.visible.filter { !$0.stableTranslation.isEmpty }.count == 1
                    && chinese.visible.contains {
                        $0.stableTranslation == "Let us have coffee at Starbucks." && $0.target == .english
                            && $0.language == .chinese && $0.languageIsFinal
                    }, "native mixed sentence fully retained size\(size)")
            let switcher = Harness()
            for value in chunks("Bonjour.") { switcher.send([source(value, "fr", status: "original")]) }
            for value in chunks("Hello.") { switcher.send([translated(value, "fr")]) }
            for value in chunks("こんにちは。") { switcher.send([source(value, "ja", status: "original")]) }
            for value in chunks("Good day") { switcher.send([translated(value, "ja")]) }
            switcher.send([translated(".", nil), end])
            expect(
                switcher.visible.map(\.source) == ["Bonjour.", "こんにちは。"],
                "sentence boundary preserves two foreign sources size\(size)")
            expect(
                switcher.visible.map(\.stableTranslation) == ["Hello.", "Good day."],
                "metadata-free punctuation inherits last native direction size\(size)")
            expect(
                switcher.visible.map(\.language) == [Language("fr"), Language("ja")]
                    && switcher.visible.allSatisfy(\.languageIsFinal),
                "distinct foreign native evidence size\(size)")
        }
        let draining = Harness()
        draining.send([source("ありがとう", "ja", status: "original"), translated("Thank", "ja")])
        let drainingID = draining.visible.first!.id
        draining.engine.endTurn()
        draining.send([translated(" you.", "ja"), end])
        expect(
            draining.visible.count == 1 && draining.visible.first?.id == drainingID,
            "local close preserves stable source/native ID")
        expect(
            draining.visible.first?.stableTranslation == "Thank you."
                && draining.visible.first?.language == Language("ja"),
            "late suffix appends without duplicating or reversing stable speech")
        let combined = Harness()
        combined.send([
            source("Hello.", "en"), end, source("Hola.", "es", status: "original"), translated("Hi.", "es"),
            end,
        ])
        expect(
            combined.visible.map(\.source) == ["Hello.", "Hola."]
                && combined.visible.allSatisfy(\.isSourceFinal),
            "several provider epochs in one frame retain ordered turns")
        let formatting = Harness()
        formatting.send([source("こんにちは", "ja", status: "original"), translated(".", "ja"), end])
        expect(
            formatting.visible.allSatisfy { $0.stableTranslation.isEmpty },
            "formatting-only translation cannot establish incoming direction")
        let invalidTarget = Harness()
        invalidTarget.send([
            source("こんにちは", "ja", status: "original"), translated("Wrong output", "ja", target: "fr"), end,
        ])
        expect(
            invalidTarget.visible.allSatisfy { $0.translation.isEmpty },
            "wrong native target cannot play to listener")
        let unknownSource = Harness()
        unknownSource.send([
            source("Unlabelled words", "xx", status: "original"), translated("Known listener output", "xx"),
            end,
        ])
        expect(
            unknownSource.visible.allSatisfy { $0.language == nil && !$0.languageIsFinal },
            "unsupported source metadata remains honest unknown")
        expect(
            unknownSource.visible.map(\.source).joined() == "Unlabelled words",
            "unsupported original tag never deletes text")
        let recoveredEnglish = Harness()
        recoveredEnglish.send([source("Please repeat that.", "en"), end], stream: 11, catchUp: true)
        expect(
            recoveredEnglish.visible.first?.isSourceFinal == true
                && recoveredEnglish.visible.first?.languageIsFinal == true,
            "catch-up outgoing has translatable canonical provider-final source")
        expect(
            recoveredEnglish.visible.first?.isPartnerEvidence == false
                && recoveredEnglish.visible.first?.target == nil,
            "catch-up completion cannot discover or fabricate a target")
        for code in ["en", "ja"] {
            let reset = Harness()
            reset.send([source("Known final prefix", code, status: code == "en" ? "none" : "original")])
            let id = reset.visible.first!.id
            reset.engine.sessionDidReset(.init(id: 0, isCatchUp: false))
            expect(
                reset.visible.first?.id == id && reset.visible.first?.source == "Known final prefix",
                "reset preserves canonical retry caption \(code)")
            expect(
                reset.visible.first?.isClosed == true && reset.visible.first?.isSourceFinal == false
                    && reset.visible.first?.languageIsFinal == true
                    && reset.visible.first?.isPartnerEvidence == false,
                "reset coherent prefix is explicit retry only, not automatic completion \(code)")
            let local = Harness()
            local.send([
                source("Final prefix", code, status: code == "en" ? "none" : "original"),
                source(" volatile tail", code, final: false),
            ])
            expect(
                local.visible.first?.languageIsFinal == false,
                "volatile source suffix blocks prefix final-language claim \(code)")
            local.engine.endTurn()
            expect(
                local.visible.first?.source == "Final prefix" && local.visible.first?.languageIsFinal == true
                    && local.visible.first?.isSourceFinal == false,
                "local close retracts volatile suffix and exposes coherent retry prefix \(code)")
        }
        let fixedAndPreview = Harness()
        fixedAndPreview.send([
            source("ありがとう", "ja", status: "original"), translated("Thank", "ja"),
            translated(" you maybe", "ja", final: false),
        ])
        expect(
            fixedAndPreview.visible.first?.translation == "Thank you maybe"
                && fixedAndPreview.visible.first?.stableTranslation == "Thank",
            "translation overlay has a separate stable prefix")
        fixedAndPreview.send([])
        expect(
            fixedAndPreview.visible.first?.translation == "Thank"
                && fixedAndPreview.visible.first?.stableTranslation == "Thank",
            "withdrawal removes only provisional native suffix")
        for listener in ["en", "ja"] {
            let foreign = listener == "en" ? "ja" : "en"
            let firstSource = listener == "en" ? "駅はどこですか。" : "Where is the station?"
            let middleSource = listener == "en" ? "Over there." : "あそこです。"
            let lastSource = listener == "en" ? "ありがとうございます。" : "Thank you."
            let firstTranslation = listener == "en" ? "Where is the station?" : "駅はどこですか。"
            let lastTranslation = listener == "en" ? "Thank you." : "ありがとうございます。"
            for size in [1, 2, 100] {
                func chunks(_ text: String) -> [String] {
                    let chars = Array(text)
                    return stride(from: 0, to: chars.count, by: size).map {
                        String(chars[$0..<min($0 + size, chars.count)])
                    }
                }
                let h = Harness(listener: Language(listener))
                for text in chunks(firstSource) { h.send([source(text, foreign, status: "original")]) }
                for text in chunks(firstTranslation) { h.send([translated(text, foreign, target: listener)]) }
                let firstID = h.visible.first!.id
                for text in chunks(middleSource) { h.send([source(text, listener)]) }
                for text in chunks(lastSource) { h.send([source(text, foreign, status: "original")]) }
                let lastID = h.visible.last!.id
                h.send([translated(lastTranslation, foreign, final: false, target: listener)])
                expect(
                    h.latest[firstID]?.translation == firstTranslation
                        && h.latest[lastID]?.translation == lastTranslation,
                    "second same-language preview belongs after listener \(listener)/\(size)")
                expect(
                    h.latest[lastID]?.stableTranslation == "",
                    "second native preview never speaks early \(listener)/\(size)")
                for text in chunks(lastTranslation) { h.send([translated(text, foreign, target: listener)]) }
                h.send([end])
                expect(
                    h.visible.map(\.source) == [firstSource, middleSource, lastSource],
                    "foreign-listener-foreign captions stay ordered \(listener)/\(size)")
                expect(
                    h.visible.map(\.stableTranslation) == [firstTranslation, "", lastTranslation],
                    "same-language native answers stay on their own rows \(listener)/\(size)")
                expect(
                    h.latest[firstID]?.id == firstID && h.latest[lastID]?.id == lastID && firstID != lastID,
                    "same-language placement preserves stable IDs \(listener)/\(size)")
            }
        }
        let unaligned = Harness()
        unaligned.send([
            source("最初です。", "ja", status: "original"), source("Okay.", "en"),
            source("次です。", "ja", status: "original"), translated("First. Next.", "ja"), end,
        ])
        expect(
            unaligned.visible.filter { !$0.source.isEmpty }.map(\.source) == ["最初です。", "Okay.", "次です。"],
            "queued repeated-language originals never lose order")
        expect(
            unaligned.visible.contains {
                $0.source.isEmpty && $0.stableTranslation == "First. Next." && $0.target == .english
            }, "unidentifiable repeated-language alignment remains honest translation-only")
        for listener in ["en", "ja"] {
            let foreign = listener == "en" ? "ja" : "en"
            let original = listener == "en" ? "あそこです。" : "It is over there."
            let ownReply = listener == "en" ? "Okay." : "わかりました。"
            let prefix = listener == "en" ? "Yes, it's" : "はい、"
            let suffix = listener == "en" ? " right here." : "あそこです。"
            for size in [1, 2, 100] {
                func chunks(_ text: String) -> [String] {
                    let chars = Array(text)
                    return stride(from: 0, to: chars.count, by: size).map {
                        String(chars[$0..<min($0 + size, chars.count)])
                    }
                }
                let h = Harness(listener: Language(listener))
                for text in chunks(original) { h.send([source(text, foreign, status: "original")]) }
                for text in chunks(prefix) { h.send([translated(text, foreign, target: listener)]) }
                let nativeID = h.visible.first!.id
                for text in chunks(ownReply) { h.send([source(text, listener)]) }
                h.send([translated(suffix, foreign, final: false, target: listener)])
                expect(
                    h.latest[nativeID]?.translation == prefix + suffix
                        && h.latest[nativeID]?.stableTranslation == prefix,
                    "native preview continuation stays on existing sentence \(listener)/\(size)")
                for text in chunks(suffix) { h.send([translated(text, foreign, target: listener)]) }
                h.send([end])
                expect(
                    h.visible.count == 2 && h.visible.map(\.source) == [original, ownReply],
                    "intervening listener never splits an unfinished incoming sentence \(listener)/\(size)")
                expect(
                    h.latest[nativeID]?.stableTranslation == prefix + suffix,
                    "native sentence keeps exact fragment order \(listener)/\(size)")
                let nativeIDs = Set(h.events.filter { !$0.stableTranslation.isEmpty }.map(\.id))
                expect(
                    nativeIDs == [nativeID],
                    "no new stable native ID for unfinished sentence suffix \(listener)/\(size)")
                let firstComplete = h.events.first {
                    $0.stableTranslation.hasSuffix(".") || $0.stableTranslation.hasSuffix("。")
                }
                expect(
                    firstComplete?.id == nativeID && firstComplete?.stableTranslation == prefix + suffix,
                    "first speech-ready incoming sentence contains its prefix before suffix \(listener)/\(size)"
                )
            }
        }
        for listener in ["en", "ja"] {
            let foreign = listener == "en" ? "ja" : "en"
            let original = listener == "en" ? "距離です。" : "It is the distance."
            let own = listener == "en" ? "Okay." : "わかりました。"
            let prefix = listener == "en" ? "It is 3." : "距離は3."
            let suffix = listener == "en" ? "14 kilometres." : "14キロです。"
            for size in [1, 2, 100] {
                func chunks(_ text: String) -> [String] {
                    let chars = Array(text)
                    return stride(from: 0, to: chars.count, by: size).map {
                        String(chars[$0..<min($0 + size, chars.count)])
                    }
                }
                let h = Harness(listener: Language(listener))
                for text in chunks(original) { h.send([source(text, foreign, status: "original")]) }
                for text in chunks(prefix) { h.send([translated(text, foreign, target: listener)]) }
                let id = h.visible.first!.id
                expect(
                    ActualSentenceHelper.completeSentences(in: prefix).isEmpty,
                    "actual consumer holds decimal prefix \(listener)/\(size)")
                for text in chunks(own) { h.send([source(text, listener)]) }
                h.send([translated(suffix, foreign, final: false, target: listener)])
                expect(
                    h.latest[id]?.translation == prefix + suffix,
                    "decimal preview keeps original incoming ID \(listener)/\(size)")
                for text in chunks(suffix) { h.send([translated(text, foreign, target: listener)]) }
                h.send([end])
                expect(
                    h.visible.count == 2 && h.visible.map(\.source) == [original, own],
                    "decimal continuation creates no extra row \(listener)/\(size)")
                expect(
                    h.latest[id]?.stableTranslation == prefix + suffix,
                    "decimal numeric meaning is unchanged \(listener)/\(size)")
                let firstReady = h.events.first {
                    !ActualSentenceHelper.completeSentences(in: $0.stableTranslation).isEmpty
                }
                expect(
                    firstReady?.id == id && firstReady?.stableTranslation == prefix + suffix,
                    "actual consumer first receives the complete ordered decimal sentence \(listener)/\(size)"
                )
            }
        }
        for ending in [";", "；", "؟", "।", "…"] {
            for size in [1, 100] {
                func chunks(_ text: String) -> [String] {
                    let chars = Array(text)
                    return stride(from: 0, to: chars.count, by: size).map {
                        String(chars[$0..<min($0 + size, chars.count)])
                    }
                }
                let first = "First" + ending
                let h = Harness()
                h.send([source("最初です。", "ja", status: "original")])
                for text in chunks(first) { h.send([translated(text, "ja")]) }
                let firstID = h.visible.first!.id
                h.send([source("Okay.", "en"), source("次です。", "ja", status: "original")])
                for text in chunks("Second.") { h.send([translated(text, "ja")]) }
                h.send([end])
                expect(
                    ActualSentenceHelper.completeSentences(in: first) == first,
                    "consumer recognizes valid delimiter \(ending)/\(size)")
                expect(
                    h.visible.map(\.stableTranslation) == [first, "", "Second."],
                    "completed native delimiter allows next owned foreign row \(ending)/\(size)")
                let ready = h.events.filter {
                    !ActualSentenceHelper.completeSentences(in: $0.stableTranslation).isEmpty
                }
                expect(
                    ready.first?.id == firstID && ready.first?.stableTranslation == first,
                    "valid delimiter preserves first speech-ready native order \(ending)/\(size)")
            }
        }
        for prefix in ["Is it 3?", "Room 5!", "“Yes.”", "(It is here.)", "First. Next"] {
            for size in [1, 2, 100] {
                func chunks(_ text: String) -> [String] {
                    let chars = Array(text)
                    return stride(from: 0, to: chars.count, by: size).map {
                        String(chars[$0..<min($0 + size, chars.count)])
                    }
                }
                let h = Harness()
                h.send([source("場所です。", "ja", status: "original")])
                for text in chunks(prefix) { h.send([translated(text, "ja")]) }
                let id = h.visible.first!.id
                expect(
                    ActualSentenceHelper.completeSentences(in: prefix) != prefix,
                    "actual consumer holds an unfinished native tail \(prefix)/\(size)")
                for text in chunks("Okay.") { h.send([source(text, "en")]) }
                h.send([translated(" Check upstairs.", "ja", final: false)])
                expect(
                    h.latest[id]?.translation == prefix + " Check upstairs.",
                    "consumer-held preview suffix stays on the original native row \(prefix)/\(size)")
                for text in chunks(" Check upstairs.") { h.send([translated(text, "ja")]) }
                h.send([end])
                expect(
                    h.visible.count == 2 && h.visible.map(\.source) == ["場所です。", "Okay."],
                    "held punctuation never creates a source-empty suffix row \(prefix)/\(size)")
                expect(
                    h.latest[id]?.stableTranslation == prefix + " Check upstairs.",
                    "held punctuation preserves the full exact native sentence \(prefix)/\(size)")
                let nativeIDs = Set(h.events.filter { !$0.stableTranslation.isEmpty }.map(\.id))
                expect(
                    nativeIDs == [id],
                    "held punctuation preserves all stable fragment ownership \(prefix)/\(size)")
                let firstReady = h.events.first {
                    !ActualSentenceHelper.completeSentences(in: $0.stableTranslation).isEmpty
                }
                expect(
                    firstReady?.id == id,
                    "consumer-held prefix becomes speech-ready before any suffix row \(prefix)/\(size)")
            }
        }
        for size in [1, 2, 100] {
            func chunks(_ text: String) -> [String] {
                let chars = Array(text)
                return stride(from: 0, to: chars.count, by: size).map {
                    String(chars[$0..<min($0 + size, chars.count)])
                }
            }
            let h = Harness()
            let fillerPrefix = "Room three, um."
            let fillerSuffix = " is on your left."
            h.send([source("三号室です。", "ja", status: "original")])
            for text in chunks(fillerPrefix) { h.send([translated(text, "ja")]) }
            let id = h.visible.first!.id
            expect(
                ActualSentenceHelper.completeSentences(in: Filler.strip(fillerPrefix, in: .english)).isEmpty,
                "actual filler normalization holds unfinished native prefix \(size)")
            h.send([source("Okay.", "en"), translated(fillerSuffix, "ja", final: false)])
            expect(
                h.latest[id]?.translation == fillerPrefix + fillerSuffix,
                "filler-normalized preview keeps original native ownership \(size)")
            for text in chunks(fillerSuffix) { h.send([translated(text, "ja")]) }
            h.send([end])
            expect(
                h.visible.count == 2 && h.visible.map(\.source) == ["三号室です。", "Okay."],
                "filler removal never creates a suffix-only row \(size)")
            expect(
                h.latest[id]?.stableTranslation == fillerPrefix + fillerSuffix,
                "raw confirmed native fragments stay lossless despite speech normalization \(size)")
            let ready = h.events.first {
                !ActualSentenceHelper.completeSentences(in: Filler.strip($0.stableTranslation, in: .english))
                    .isEmpty
            }
            expect(
                ready?.id == id
                    && ready.map { Filler.strip($0.stableTranslation, in: .english) }
                        == "Room three is on your left.",
                "actual normalized consumer first speaks full ordered sentence \(size)")
            let nativeIDs = Set(h.events.filter { !$0.stableTranslation.isEmpty }.map(\.id))
            expect(nativeIDs == [id], "normalized native fragments keep one stable ID \(size)")
        }
        print("Automatic Soniox regression: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
