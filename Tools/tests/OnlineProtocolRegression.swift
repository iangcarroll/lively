import Foundation

@main struct OnlineProtocolRegression {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            print("FAIL: " + message)
            exit(1)
        }
    }

    static func until(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(false, "timed out waiting for confirmed native speech: " + message)
    }

    static func original(_ text: String, _ language: String) -> [String: Any] {
        ["text": text, "language": language, "translation_status": "original", "is_final": true]
    }

    static func translated(_ text: String, _ source: String) -> [String: Any] {
        ["text": text, "source_language": source, "language": source == "en" ? "ja" : "en",
         "translation_status": "translation", "is_final": true]
    }

    static func preservesOriginalWords(_ captions: [String], expected: String) -> Bool {
        var remaining = expected[...]
        for caption in captions where !caption.isEmpty {
            // A new row can trim its leading whitespace; internal words and
            // spaces must still match exactly and in their original order.
            while let first = remaining.first, first.isWhitespace, !remaining.hasPrefix(caption) {
                remaining.removeFirst()
            }
            guard remaining.hasPrefix(caption) else { return false }
            remaining = remaining.dropFirst(caption.count)
        }
        return remaining.allSatisfy(\.isWhitespace)
    }

    static func englishInHeadphones(_ text: String) -> Calls.Line {
        .init(text: text, language: .english, output: .headphones)
    }

    static func japaneseOnSpeaker(_ text: String) -> Calls.Line {
        .init(text: text, language: Language("ja"), output: .speaker)
    }

    static func main() async {
        let end: [String: Any] = ["text": "<end>", "is_final": true]
        let question = "Where is the station?", reply = "あそこです。"
        let translatedQuestion = "駅はどこですか？", translatedReply = "It's over there."
        var cases: [(name: String, frames: [[[String: Any]]], sources: [String], speech: [Calls.Line])] = [
            ("rapid reply", [
                [original(question, "en"), translated(translatedQuestion, "en")],
                [original(reply, "ja")], [translated(translatedReply, "ja"), end]
            ], [question, reply], [japaneseOnSpeaker(translatedQuestion), englishInHeadphones(translatedReply)]),
            ("reverse reply", [
                [original(translatedQuestion, "ja"), translated(question, "ja")],
                [original(translatedReply, "en")], [translated(reply, "en"), end]
            ], [translatedQuestion, translatedReply], [englishInHeadphones(question), japaneseOnSpeaker(reply)]),
            ("delayed first translation", [
                [original(question, "en"), original(reply, "ja")],
                [translated(translatedQuestion, "en")], [translated(translatedReply, "ja"), end]
            ], [question, reply], [japaneseOnSpeaker(translatedQuestion), englishInHeadphones(translatedReply)]),
            ("four queued source groups", [
                [original(question, "en"), original(reply, "ja"),
                 original("Thank you.", "en"), original("どういたしまして。", "ja")],
                [translated(translatedQuestion, "en"), translated(translatedReply, "ja"),
                 translated("ありがとうございます。", "en"), translated("You are welcome.", "ja"), end]
            ], [question, reply, "Thank you.", "どういたしまして。"],
               [japaneseOnSpeaker(translatedQuestion), englishInHeadphones(translatedReply),
                japaneseOnSpeaker("ありがとうございます。"), englishInHeadphones("You are welcome.")]),
            ("incremental folded reply", [
                [original("Is it this one", "en"), translated("これですか", "en")],
                [original("はい", "ja")], [original(" OK thanks", "en")],
                [translated("Yes", "ja")], [end]
            ], ["Is it this one", "はい", " OK thanks"], [japaneseOnSpeaker("これですか"), englishInHeadphones("Yes")]),
            ("incremental reverse folded reply", [
                [original("これですか", "ja"), translated("Is it this one", "ja")],
                [original("Yes", "en")], [original(" 了解です", "ja")],
                [translated("はい", "en")], [end]
            ], ["これですか", "Yes", " 了解です"], [englishInHeadphones("Is it this one"), japaneseOnSpeaker("はい")]),
            ("ambiguous source ownership", [
                [original("One", "en"), original("二", "ja"), original("Three", "en"), original("四", "ja")],
                [translated("一", "en"), translated("Reply.", "ja"), end]
            ], [], [japaneseOnSpeaker("一"), englishInHeadphones("Reply.")])
        ]

        for reverse in [false, true] {
            let firstLanguage = reverse ? "ja" : "en", replyLanguage = reverse ? "en" : "ja"
            let first = reverse ? "これですか" : "Is it this one"
            let second = reverse ? "Yes" : "はい"
            let continuation = reverse ? [" 了解", " ありがとう"] : [" OK", " thanks"]
            let firstTranslation = reverse ? "Is it this one" : "これですか"
            let replyTranslation = reverse ? "はい" : "Yes"
            let continuationTranslation = reverse ? "OK, thanks" : "了解、ありがとう"
            let firstLine = reverse ? englishInHeadphones(firstTranslation) : japaneseOnSpeaker(firstTranslation)
            let replyLine = reverse ? japaneseOnSpeaker(replyTranslation) : englishInHeadphones(replyTranslation)
            let continuationLine = reverse ? englishInHeadphones(continuationTranslation) : japaneseOnSpeaker(continuationTranslation)
            cases.append(("incremental multi-token continuation reverse=\(reverse)", [
                [original(first, firstLanguage), translated(firstTranslation, firstLanguage)],
                [original(second, replyLanguage)], continuation.map { original($0, firstLanguage) },
                [translated(replyTranslation, replyLanguage)],
                [translated(continuationTranslation, firstLanguage)], [end]
            ], [first, second] + continuation, [firstLine, replyLine, continuationLine]))
            let translationParts = reverse ? ["Is it", " this one"] : ["これ", "ですか"]
            cases.append(("incremental first translation spans fold reverse=\(reverse)", [
                [original(first, firstLanguage), translated(translationParts[0], firstLanguage)],
                [original(second, replyLanguage)],
                [original(continuation.joined(), firstLanguage)],
                [translated(translationParts[1], firstLanguage)],
                [translated(replyTranslation, replyLanguage)], [end]
            ], [first, second, continuation.joined()], [firstLine, replyLine]))
        }
        for reverse in [false, true] {
            let firstLanguage = reverse ? "ja" : "en", replyLanguage = reverse ? "en" : "ja"
            let first = reverse ? "これですか" : "Is it this one", second = reverse ? "Yes" : "はい"
            let translationParts = reverse ? ["Is it", " this one"] : ["これ", "ですか"]
            let replyTranslation = reverse ? "はい" : "Yes"
            let firstLine = reverse ? englishInHeadphones(translationParts.joined()) : japaneseOnSpeaker(translationParts.joined())
            let replyLine = reverse ? japaneseOnSpeaker(replyTranslation) : englishInHeadphones(replyTranslation)
            for queued in [false, true] {
                let frames: [[[String: Any]]]
                if queued {
                    frames = [[original(first, firstLanguage)], [original(second, firstLanguage)],
                              [translated(translationParts[0], firstLanguage)],
                              [translated(translationParts[1], firstLanguage)],
                              [translated(replyTranslation, replyLanguage)], [end]]
                } else {
                    frames = [[original(first, firstLanguage), translated(translationParts[0], firstLanguage)],
                              [original(second, firstLanguage)],
                              [translated(translationParts[1], firstLanguage)],
                              [translated(replyTranslation, replyLanguage)], [end]]
                }
                cases.append(("incremental single mistagged reply reverse=\(reverse), queued=\(queued)",
                              frames, [first, second], [firstLine, replyLine]))
            }
        }
        for reverse in [false, true] {
            let firstLanguage = reverse ? "ja" : "en", replyLanguage = reverse ? "en" : "ja"
            let firstParts = reverse ? ["駅は", "どこ", "です", "か？"] : ["Where", " is", " the", " station?"]
            let translationParts = reverse ? ["Where is", " the station?"] : ["駅は", "どこですか？"]
            let replyParts = reverse ? ["It's", " over there."] : ["あそこ", "です。"]
            let replyTranslations = reverse ? ["あそこ", "です。"] : ["It's", " over there."]
            let firstLine = reverse ? englishInHeadphones(translationParts.joined()) : japaneseOnSpeaker(translationParts.joined())
            let replyLine = reverse ? japaneseOnSpeaker(replyTranslations.joined()) : englishInHeadphones(replyTranslations.joined())
            for reset in [false, true] {
                cases.append(("clean mid-translation reply reverse=\(reverse), reset=\(reset)", [
                    [original(firstParts[0], firstLanguage), original(firstParts[1], firstLanguage),
                     translated(translationParts[0], firstLanguage)],
                    [original(firstParts[2], firstLanguage), original(firstParts[3], firstLanguage),
                     translated(translationParts[1], firstLanguage)],
                    [original(replyParts[0], replyLanguage)],
                    [translated(replyTranslations[0], replyLanguage)],
                    [original(replyParts[1], replyLanguage), translated(replyTranslations[1], replyLanguage)],
                    [end]
                ], [firstParts.joined(), replyParts.joined()], [firstLine, replyLine]))
            }
        }
        // Provider token boundaries are independent of words and sentences.
        // Replay the same cases with two-character and single-character tokens.
        let wholeTokenCases = cases
        for width in [2, 1] {
            for scenario in wholeTokenCases {
                let frames = scenario.frames.map { frame in
                    frame.flatMap { token -> [[String: Any]] in
                        guard let text = token["text"] as? String, !text.hasPrefix("<") else { return [token] }
                        let characters = Array(text)
                        return stride(from: 0, to: characters.count, by: width).map { start in
                            var piece = token
                            piece["text"] = String(characters[start..<min(start + width, characters.count)])
                            return piece
                        }
                    }
                }
                cases.append((scenario.name + " token-width=\(width)", frames, scenario.sources, scenario.speech))
            }
        }

        for scenario in cases {
            Calls.reset()
            let store = ConversationStore()
            let parser = SonioxTranscriber(.init(credential: .apiKey("unused-local-test"), languages: store.languages))
            store.settings.pipeline = .init(engine: parser, translator: nil, fallbackTranslator: nil)
            store.beginListening()
            for (index, frame) in scenario.frames.enumerated() {
                if scenario.name.hasPrefix("clean"), scenario.name.contains("reset=true"), index == scenario.frames.count - 1 {
                    parser.sessionDidReset(.init(id: 1, isCatchUp: false))
                } else {
                    _ = parser.receive(.json(["tokens": frame]), on: .init(id: 1, isCatchUp: false))
                }
                if scenario.name.hasPrefix("clean"), index == 3 {
                    let partialReply = scenario.frames[2].compactMap { $0["text"] as? String }.joined()
                    let rows = store.visibleUtterances
                    check(rows.count == 2 && rows[0].source == scenario.sources[0]
                          && rows[0].language == scenario.speech[1].language
                          && rows[1].source == partialReply && rows[1].language == scenario.speech[0].language,
                          "clean reply has its own correct side before the endpoint: " + scenario.name)
                }
                if scenario.name.hasPrefix("clean"), index == 4 {
                    check(Calls.lines.sorted { $0.text < $1.text } == scenario.speech.sorted { $0.text < $1.text },
                          "complete reply speech has the correct voice and output before endpoint/reset: " + scenario.name)
                }
            }
            if scenario.name.hasPrefix("ambiguous source ownership") || scenario.name.hasPrefix("incremental") {
                // Exercise the real 1.5 s native-tail flush without adding punctuation.
                try? await Task.sleep(for: .milliseconds(1_650))
                await until(scenario.name) { Calls.lines.count == scenario.speech.count }
            }
            if scenario.name.hasPrefix("incremental") {
                check(preservesOriginalWords(store.visibleUtterances.map(\.source), expected: scenario.sources.joined()),
                      "incremental corrections retain every original word for " + scenario.name
                      + ": actual=" + String(describing: store.visibleUtterances.map(\.source))
                      + ", expected=" + String(describing: scenario.sources))
            } else if scenario.name.hasPrefix("ambiguous source ownership") {
                check(store.visibleUtterances.map(\.source).joined() == "One二Three四",
                      "ambiguous ownership retains every original word")
                check(store.visibleUtterances.contains {
                    $0.source.isEmpty && $0.isTranslationOnly && $0.language == Language("ja") && $0.translation == "Reply."
                }, "confirmed translation-only output is visible without a fabricated source")
            } else {
                check(store.visibleUtterances.map(\.source) == scenario.sources,
                      "parser/store preserves source ownership for " + scenario.name)
            }
            check(Calls.lines.map(\.text).sorted() == scenario.speech.map(\.text).sorted(),
                  "every confirmed translation is spoken once for " + scenario.name)
            check(Calls.lines.sorted { $0.text < $1.text } == scenario.speech.sorted { $0.text < $1.text },
                  "each translated sentence keeps its predetermined language and output for " + scenario.name)
            store.close()
        }
        print("Online protocol integration: \(assertions) assertions passed")
    }
}
