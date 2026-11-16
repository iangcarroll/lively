import Foundation

@main struct AutomaticConversationRegression {
    static var assertions = 0
    static let english = Language.english
    static let japanese = Language("ja")
    static let spanish = Language("es")
    static let legacy = LanguagePair(first: Language("fr"), second: Language("de"))

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { print("FAIL: " + message); exit(1) }
    }

    static func until(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(condition(), message)
    }

    static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    static func store(listener: Language = english) -> ConversationStore {
        let subject = ConversationStore()
        subject.isListening = false
        subject.settings.conversationMode = .automatic
        subject.settings.speechListenerLanguage = listener
        subject.settings.languages = legacy
        subject.settings.pipeline = .init(engine: TestEngine(), translator: AppleTranslator(), fallbackTranslator: nil)
        subject.beginListening()
        return subject
    }

    static func send(_ subject: ConversationStore, id: Int, source: String, language: Language?,
                     target: Language? = nil, translation: String = "", stable: String? = nil,
                     languageFinal: Bool = true, sourceFinal: Bool = true,
                     closed: Bool = true, catchUp: Bool = false, partnerEvidence: Bool? = nil) {
        subject.handle(.autoSegment(.init(id: id, source: source, language: language,
            languageIsFinal: languageFinal, target: target, translation: translation,
            stableTranslation: stable ?? translation, isClosed: closed,
            isSourceFinal: sourceFinal, isCatchUp: catchUp,
            isPartnerEvidence: partnerEvidence ?? (languageFinal && sourceFinal && !catchUp))))
    }

    static func incoming(_ text: String, listener: Language = english) -> Calls.Line {
        .init(text: text, language: listener, output: .headphones)
    }

    static func outgoing(_ text: String, target: Language) -> Calls.Line {
        .init(text: text, language: target, output: .speaker)
    }

    static func englishFirst() async {
        Calls.reset()
        let subject = store()
        check(subject.isAutomaticLanguageMode && subject.listenerLanguage == english,
              "automatic mode keeps the saved listener independent of the unrelated legacy pair")
        send(subject, id: 1, source: "Where is the station?", language: english)
        check(subject.visibleUtterances.count == 1, "user-first speech creates one readable caption")
        let first = subject.visibleUtterances[0]
        check(first.isAutomatic && first.sourceLanguage == english && first.target == nil,
              "user-first speech has no invented destination from the old pair")
        check(first.isAwaitingLanguage && first.translationState == .awaitingPartner && !first.needsTranslation,
              "an unknown partner is a waiting state, not a failed or active translation")
        check(first.listenerText == "Where is the station?" && first.partnerText.isEmpty && first.otherLanguage == nil,
              "waiting projections do not show a source or translation under a fabricated foreign language")
        check(subject.detectedPartnerLanguage == nil && Calls.requests.isEmpty && Calls.lines.isEmpty,
              "no partner means no translation API call or public speech")
        check(subject.settings.languages == legacy && subject.settings.speechListenerLanguage == english,
              "discovery does not overwrite saved manual or headphone settings")
        subject.isOnline = false
        check(!subject.fallbackAllowed, "no-pair mode never silently falls back to the unrelated explicit offline language")
        subject.isOnline = true
        subject.close()
        await settle()
    }

    static func foreignFirstAndListener() async {
        for listener in [english, spanish] {
            Calls.reset()
            let subject = store(listener: listener)
            let translated = listener == english ? "Where is the station?" : "¿Dónde está la estación?"
            send(subject, id: 2, source: "駅はどこですか？", language: japanese,
                 target: listener, translation: translated)
            let first = subject.visibleUtterances.first
            check(subject.detectedPartnerLanguage == japanese, "first confirmed foreign speech selects Japanese without a pair")
            check(first?.sourceLanguage == japanese && first?.target == listener && first?.otherLanguage == japanese,
                  "incoming direction captures the actual foreign source and saved listener")
            check(first?.listenerText == translated && first?.partnerText == "駅はどこですか？",
                  "incoming layout projections use the turn's captured languages")
            check(first?.text(in: Language("de")) == "", "a legacy third-language header cannot display unrelated translated text")
            check(Calls.lines == [incoming(translated, listener: listener)],
                  "the predetermined incoming voice and headphone destination do not assume English")
            check(subject.settings.languages == legacy, "foreign discovery preserves manual-pair preferences")
            subject.close()
            await settle()
        }
    }

    static func boundedSilentBackfill() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        let questions = (0..<6).map { "Question number \($0)." }
        for (id, question) in questions.enumerated() { send(subject, id: id, source: question, language: english) }
        let pending = subject.visibleUtterances
        check(Calls.requests.isEmpty && pending.allSatisfy { $0.target == nil }, "all user-first questions wait without network requests")
        send(subject, id: 10, source: "あそこです。", language: japanese, target: english, translation: "It is over there.")
        await until("only the newest three completed questions request backfill") { Calls.requests.count == 3 }
        check(pending.allSatisfy { $0.target == japanese && $0.suppressesAutomaticSpeech },
              "first partner binds every waiting question once and suppresses stale spoken questions")
        check(Set(Calls.requests.map(\.text)) == Set(questions.suffix(3)),
              "backfill's predetermined request cap chooses only the newest three completed questions")
        check(Calls.requests.allSatisfy { $0.source == english && $0.target == japanese },
              "every backfill request has independently expected English-to-Japanese direction")
        check(pending.prefix(3).allSatisfy { $0.translation.isEmpty && $0.translationState == .idle },
              "older bound questions stay neutral and readable instead of claiming an active request")
        for index in Calls.requests.indices { Calls.complete(index) }
        await until("the three backfills become visible") { pending.suffix(3).allSatisfy { !$0.translation.isEmpty } }
        check(Calls.lines == [incoming("It is over there.")], "backfill never speaks an earlier question after its answer")
        check(pending[0].listenerText == questions[0] && pending[0].target == japanese,
              "unrequested old questions retain their source and captured destination")
        subject.retryTranslation(pending[0])
        await until("explicit retry can translate an older bound question") { Calls.requests.count == 4 }
        check(Calls.requests[3].text == questions[0] && Calls.requests[3].target == japanese,
              "manual retry uses the original captured target instead of a cached default")
        Calls.complete(3)
        await until("explicit old-question translation completes") { !pending[0].translation.isEmpty }
        let rowCount = subject.visibleUtterances.count
        send(subject, id: 0, source: "A late obsolete native revision.", language: english)
        check(subject.visibleUtterances.count == rowCount && pending[0].source == questions[0],
              "a retried automatic row remains retired from native updates without creating a duplicate ID row")
        subject.close()
        await settle()
    }

    static func laterPartnerAndDelayedRequests() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "おはようございます。", language: japanese, target: english, translation: "Good morning.")
        let japaneseHistory = subject.visibleUtterances[0]
        send(subject, id: 2, source: "Where is the train?", language: english)
        await until("new outgoing speech uses the discovered Japanese destination") { Calls.requests.count == 1 }
        let oldQuestion = subject.visibleUtterances[1]
        send(subject, id: 3, source: "El tren está allí.", language: spanish, target: english, translation: "The train is there.")
        check(subject.detectedPartnerLanguage == japanese, "one changed-language sentence cannot redirect the next reply")
        send(subject, id: 30, source: "Puede esperar aquí.", language: spanish, target: english, translation: "You can wait here.")
        send(subject, id: 2, source: "Where is the train?", language: english)
        check(oldQuestion.target == japanese, "a later update of an existing user turn cannot adopt a newly detected partner")
        send(subject, id: 4, source: "Thank you for helping me.", language: english)
        await until("later outgoing speech uses the newly confirmed Spanish destination") { Calls.requests.count == 2 }
        let newQuestion = subject.visibleUtterances[4]
        check(subject.detectedPartnerLanguage == spanish && oldQuestion.target == japanese && newQuestion.target == spanish,
              "later discovery changes future destinations without retargeting an existing request")
        check(Calls.requests[0].source == english && Calls.requests[0].target == japanese
              && Calls.requests[1].source == english && Calls.requests[1].target == spanish,
              "concurrent outgoing requests retain independently expected directions")
        check(japaneseHistory.sourceLanguage == japanese && japaneseHistory.partnerText == "おはようございます。"
              && japaneseHistory.listenerText == "Good morning." && japaneseHistory.text(in: spanish).isEmpty,
              "older Japanese history cannot be displayed as Spanish after the partner changes")
        Calls.complete(1); Calls.complete(0)
        await until("out-of-order translation completions settle on their own rows") {
            oldQuestion.translationState == .current && newQuestion.translationState == .current
        }
        let expected = [incoming("Good morning."), incoming("The train is there."), incoming("You can wait here."),
                        outgoing("es:Thank you for helping me.", target: spanish),
                        outgoing("ja:Where is the train?", target: japanese)]
        check(Calls.lines == expected, "delayed results preserve each predetermined text, synthesis language and output")
        check(subject.visibleUtterances.map(\.source) == ["おはようございます。", "Where is the train?", "El tren está allí.", "Puede esperar aquí.", "Thank you for helping me."],
              "language changes and late results cannot reorder or clear transcript history")
        subject.close()
        await settle()
    }

    static func evidenceGates() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "My question is waiting.", language: english)
        let pending = subject.visibleUtterances[0]
        send(subject, id: 0, source: ".", language: japanese, target: english)
        await settle()
        check(subject.detectedPartnerLanguage == nil && pending.target == nil,
              "formatting-only language metadata cannot select a partner or bind waiting speech")
        check(Calls.requests.isEmpty, "formatting-only input cannot start a translation API request")
        send(subject, id: 2, source: "暫定", language: japanese, target: english,
             translation: "A guess.", stable: "", languageFinal: false, sourceFinal: false, closed: false)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil && Calls.requests.isEmpty && Calls.lines.isEmpty,
              "a provisional language cannot select a partner, bind questions or speak an unstable guess")
        send(subject, id: 6, source: "Unconfirmed language", language: japanese, target: english,
             translation: "Still unconfirmed.", languageFinal: false, sourceFinal: true, partnerEvidence: true)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil,
              "provider completion cannot substitute for independent final language evidence")
        send(subject, id: 2, source: "Actually English.", language: english)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil, "a revised final user-language turn cannot retain its provisional foreign label")
        send(subject, id: 3, source: "Unknown source", language: nil, target: english, translation: "Known English output.")
        check(subject.detectedPartnerLanguage == nil && pending.target == nil && Calls.requests.isEmpty,
              "target-only metadata cannot invent the source language or outgoing destination")
        check(subject.visibleUtterances.last?.sourceLanguage == nil,
              "a known translation target cannot silently label an unclassified source as the user")
        check(Calls.lines.allSatisfy { $0.language == english && $0.output == .headphones },
              "unknown-source output, if supported, remains private in the explicitly supplied target")
        send(subject, id: 4, source: "以前の発言", language: japanese, target: english, translation: "An older phrase.", catchUp: true, partnerEvidence: true)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil && Calls.requests.isEmpty,
              "catch-up speech cannot choose a current partner or backfill pending live questions")
        send(subject, id: 5, source: "まだ途中", language: japanese, target: english,
             translation: "Still speaking.", sourceFinal: false, closed: true, partnerEvidence: true)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil,
              "local closure is not provider-final source evidence for partner discovery")
        send(subject, id: 7, source: "単なる字幕です。", language: japanese, target: english,
             translation: "Only a caption.", partnerEvidence: false)
        check(subject.detectedPartnerLanguage == nil && pending.target == nil,
              "coherent final text remains independent of live partner-discovery authorization")
        send(subject, id: 5, source: "発言が終わりました。", language: japanese, target: english,
             translation: "The sentence is complete.", sourceFinal: true)
        check(subject.detectedPartnerLanguage == japanese && pending.target == japanese,
              "the provider-final revision can select the partner and bind a waiting destination")
        subject.close()
        await settle()
    }

    static func sourceEvidenceBeforeTranslation() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "Could you help me?", language: english)
        let pending = subject.visibleUtterances[0]
        send(subject, id: 2, source: "はい、駅はあそこです。", language: japanese)
        check(subject.detectedPartnerLanguage == japanese && pending.target == japanese,
              "confirmed live foreign originals can establish the partner before native translation arrives")
        let incomingTurn = subject.visibleUtterances[1]
        check(incomingTurn.sourceLanguage == japanese && incomingTurn.target == nil && incomingTurn.isSourceOnly
              && incomingTurn.listenerText.isEmpty && incomingTurn.partnerText == "はい、駅はあそこです。",
              "raw foreign originals remain display-only without a fabricated native target or translation")
        await until("source evidence starts only the permitted user-question backfill") { Calls.requests.count == 1 }
        check(Calls.requests[0].text == "Could you help me?" && Calls.requests[0].target == japanese && Calls.lines.isEmpty,
              "missing native translation cannot speak or replace the original caption with a guessed result")
        send(subject, id: 2, source: "はい、駅はあそこです。", language: japanese,
             target: english, translation: "Yes, the station is over there.")
        check(subject.visibleUtterances[1] === incomingTurn && Calls.lines == [incoming("Yes, the station is over there.")],
              "a later native translation updates its original row and uses the predetermined private route")
        Calls.complete(0)
        await until("the separately bound earlier question finishes visibly") { !pending.translation.isEmpty }
        check(Calls.lines == [incoming("Yes, the station is over there.")], "late question backfill remains silent after native translation")
        subject.close()
        await settle()
    }

    static func translationOnlyDoesNotDiscover() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "I have a question.", language: english)
        let pending = subject.visibleUtterances[0]
        send(subject, id: 2, source: "", language: japanese, target: english, translation: "Please wait.")
        check(subject.detectedPartnerLanguage == nil && pending.target == nil && Calls.requests.isEmpty,
              "a source-empty native translation alone cannot select a current partner or backfill questions")
        check(subject.visibleUtterances.last?.isTranslationOnly == true
              && subject.visibleUtterances.last?.source.isEmpty == true && Calls.lines == [incoming("Please wait.")],
              "source-unavailable native speech stays visible and privately routable without fabricated original words")
        send(subject, id: 3, source: "ここで待ってください。", language: japanese)
        check(subject.detectedPartnerLanguage == japanese && pending.target == japanese,
              "separate provider-final original evidence can establish the partner afterward")
        await until("separate original evidence releases only the waiting user-question request") { Calls.requests.count == 1 }
        Calls.complete(0)
        await until("that earlier question receives visible silent backfill") { !pending.translation.isEmpty }
        check(Calls.lines == [incoming("Please wait.")], "separate raw and translated provider runs cannot duplicate native speech")
        subject.close()
        await settle()
    }

    static func sharedWordDoesNotSelectPartner() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "A question for someone.", language: english)
        let pending = subject.visibleUtterances[0]
        send(subject, id: 2, source: "No.", language: spanish, target: english, translation: "No.")
        await settle()
        check(subject.detectedPartnerLanguage == nil && pending.target == nil && Calls.requests.isEmpty,
              "an unchanged shared word cannot select an outgoing language for waiting user speech")
        check(Calls.lines == [incoming("No.")], "a confirmed passthrough can remain privately audible without selecting a partner")
        subject.close()
        await settle()
    }

    static func modelDirections() {
        let session = UUID()
        let unknown = Utterance(automaticSource: "Words without a tag", listenerLanguage: english, sessionID: session)
        check(unknown.sourceLanguage == nil && unknown.target == nil && unknown.isAwaitingLanguage,
              "the actual automatic model never substitutes its compatibility pair as a known direction")
        check(!unknown.needsTranslation && unknown.text(in: japanese).isEmpty,
              "an unclassified model cannot request translation or project text into an unrelated language")
        let question = Utterance(automaticSource: "A question", language: english, listenerLanguage: english, sessionID: session)
        check(question.bindAutomaticTarget(japanese) && !question.bindAutomaticTarget(spanish) && question.target == japanese,
              "the actual model binds a pending destination only once")
        question.translation = "質問"
        question.translatedSource = question.trimmedSource
        question.translatedLanguage = english
        question.translatedTarget = japanese
        check(!question.needsTranslation, "a translation records its actual source and captured target")
        question.correctAutomaticTarget(spanish)
        check(question.needsTranslation, "target correction invalidates an old translation even when source words and language are unchanged")
        question.setSource("Una pregunta", language: spanish)
        question.correctAutomaticTarget(english)
        check(question.sourceLanguage == spanish && question.target == english && question.translation.isEmpty,
              "a source correction can replace an unfinished direction without retaining old translated text")
    }

    static func contradictoryMetadata() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "An unclassified phrase.", language: Language("zz"))
        check(subject.detectedPartnerLanguage == nil && Calls.requests.isEmpty,
              "an unsupported source code cannot select a partner or start a guessed translation")
        send(subject, id: 2, source: "電車はあそこです。", language: japanese,
             target: spanish, translation: "El tren está allí.")
        check(subject.detectedPartnerLanguage == nil,
              "an explicitly contradictory translation target cannot select a partner")
        check(!Calls.lines.contains { $0.text == "El tren está allí." },
              "contradictory target metadata is never relabeled or spoken through the user's route")
        check(subject.visibleUtterances.last?.sourceLanguage == japanese
              && subject.visibleUtterances.last?.target == nil && subject.visibleUtterances.last?.isSourceOnly == true,
              "contradictory target metadata leaves an honest source-only caption without a guessed native translation")
        subject.close()
        await settle()

        Calls.reset(); Calls.automaticResponses = false
        let corrected = store()
        send(corrected, id: 1, source: "おはよう。", language: japanese, target: english, translation: "Good morning.")
        send(corrected, id: 2, source: "A provisional guess", language: english,
             languageFinal: false, sourceFinal: false, closed: false)
        try? await Task.sleep(for: .milliseconds(350))
        check(Calls.requests.isEmpty, "an unconfirmed user-language guess cannot request speech in the current foreign language")
        send(corrected, id: 2, source: "Buenos días.", language: spanish, target: english, translation: "Good day.")
        check(corrected.detectedPartnerLanguage == japanese && corrected.visibleUtterances.last?.sourceLanguage == spanish
              && corrected.visibleUtterances.last?.target == english,
              "a final foreign correction replaces its unfinished direction without treating one changed-language row as a partner switch")
        check(Calls.lines == [incoming("Good morning."), incoming("Good day.")] && Calls.requests.isEmpty,
              "wrong provisional classification cannot leak outgoing speech or leave a stale text request")
        corrected.close()
        await settle()
    }

    static func modeAndResetBoundaries() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "駅はどこですか？", language: japanese, target: english, translation: "Where is the station?")
        let previous = subject.visibleUtterances[0]
        let session = previous.automaticSessionID
        subject.handle(.sessionReset)
        check(subject.detectedPartnerLanguage == japanese && subject.visibleUtterances.first === previous,
              "transport reset preserves learned context and visible source history")
        subject.endListening(); subject.beginListening()
        check(subject.detectedPartnerLanguage == japanese && subject.visibleUtterances.first === previous,
              "warm microphone pause and resume preserve the current partner and history")
        let currentEngine = subject.engine
        let oldCallback = currentEngine?.onEvent
        subject.hardRelease()
        subject.settings.pipeline = .init(engine: TestEngine(), translator: AppleTranslator(), fallbackTranslator: nil)
        subject.beginListening()
        let french = Language("fr")
        send(subject, id: 1, source: "Bonjour.", language: french, target: english, translation: "Hello again.")
        check(subject.visibleUtterances.count == 2 && subject.visibleUtterances.first === previous
              && previous.source == "駅はどこですか？" && subject.visibleUtterances.last?.source == "Bonjour.",
              "a replacement engine reusing a provider-local ID cannot overwrite old source history")
        let historyCount = subject.visibleUtterances.count
        oldCallback?(.autoSegment(.init(id: 44, source: "Respuesta obsoleta", language: spanish,
            languageIsFinal: true, target: english, translation: "An obsolete reply.",
            stableTranslation: "An obsolete reply.", isClosed: true, isSourceFinal: true, isCatchUp: false)))
        check(subject.visibleUtterances.count == historyCount && subject.detectedPartnerLanguage != spanish,
              "an obsolete engine callback cannot append history or change automatic language context")
        subject.clear()
        check(subject.visibleUtterances.isEmpty && subject.detectedPartnerLanguage == nil,
              "clear starts an unlearned conversation without changing saved user language")
        send(subject, id: 1, source: "A fresh question.", language: english)
        let fresh = subject.visibleUtterances.first
        check(fresh?.target == nil && fresh?.automaticSessionID != session,
              "provider-local ID reuse after clear creates a new waiting turn instead of reviving old directions")
        check(subject.settings.speechListenerLanguage == english && subject.settings.languages == legacy,
              "conversation reset preserves independent saved preferences")
        subject.close()
        await settle()

        let unsupported = ConversationStore()
        unsupported.settings.conversationMode = .automatic
        unsupported.settings.providerID = "voxtral"
        check(!unsupported.settings.usesAutomaticLanguageDetection,
              "unsupported providers cannot silently claim no-pair automatic recognition")
        unsupported.close()
    }

    static func expiredContext() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "An unanswered old question.", language: english)
        let old = subject.visibleUtterances[0]
        subject.automaticLastActivity = Date().addingTimeInterval(-601)
        send(subject, id: 2, source: "Hola, buenos días.", language: spanish, target: english, translation: "Hello, good morning.")
        check(subject.detectedPartnerLanguage == spanish && old.target == nil && Calls.requests.isEmpty,
              "discovery after the ten-minute inactivity limit cannot bind or request stale questions")
        check(subject.visibleUtterances.first === old && old.source == "An unanswered old question.",
              "context expiration preserves original history instead of clearing the transcript")
        send(subject, id: 3, source: "A question for this encounter.", language: english)
        await until("fresh outgoing speech uses the new encounter") { Calls.requests.count == 1 }
        check(subject.visibleUtterances.last?.automaticSessionID != old.automaticSessionID
              && Calls.requests[0].text == "A question for this encounter." && Calls.requests[0].target == spanish,
              "new-session request identity and destination remain independent of stale pending history")
        Calls.complete(0)
        await until("fresh encounter translation completes") { subject.visibleUtterances.last?.translationState == .current }
        subject.close()
        await settle()
    }

    static func clearCancelsDelayedTranslation() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        send(subject, id: 2, source: "This belongs to the old conversation.", language: english)
        await until("old automatic request is held before clear") { Calls.requests.count == 1 }
        let abandoned = subject.visibleUtterances[1]
        subject.clear()
        send(subject, id: 3, source: "This is a new question.", language: english)
        send(subject, id: 4, source: "La estación está aquí.", language: spanish, target: english, translation: "The station is here.")
        await until("fresh context has one new Spanish backfill request") { Calls.requests.count == 2 }
        let fresh = subject.visibleUtterances[0]
        Calls.complete(0)
        await settle()
        check(subject.detectedPartnerLanguage == spanish && fresh.target == spanish && fresh.translation.isEmpty,
              "late abandoned translation cannot populate or retarget the fresh automatic context")
        check(!subject.visibleUtterances.contains { $0 === abandoned }
              && !Calls.lines.contains { $0.text == "ja:This belongs to the old conversation." },
              "clear retires old history and cancels its delayed public speech")
        check(Calls.requests[1].text == "This is a new question." && Calls.requests[1].target == spanish,
              "the fresh pending question uses only independently confirmed new-session evidence")
        Calls.complete(1)
        await until("fresh backfill completes without old-session interference") { !fresh.translation.isEmpty }
        subject.close()
        await settle()
    }

    static func localClosureDoesNotCompleteBackfill() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "An unfinished question", language: english, sourceFinal: false, closed: true)
        let pending = subject.visibleUtterances[0]
        send(subject, id: 2, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        subject.beginTranslation(pending)
        await settle()
        check(pending.target == japanese && !pending.isAutomaticSourceFinal && Calls.requests.isEmpty,
              "first discovery may bind a locally closed turn but cannot backfill its unfinished provider source")
        send(subject, id: 1, source: "An unfinished question is now complete.", language: english)
        await settle()
        check(Calls.requests.isEmpty && pending.translationState == .idle,
              "provider completion after discovery cannot activate an earlier incomplete question outside the backfill budget")
        subject.retryTranslation(pending)
        await until("explicit retry releases the previously bound full question") { Calls.requests.count == 1 }
        check(Calls.requests[0].text == "An unfinished question is now complete." && Calls.requests[0].target == japanese,
              "explicit retry uses the actual complete source and the target captured at first discovery")
        Calls.complete(0)
        await until("the completed late question becomes readable") { !pending.translation.isEmpty }
        check(Calls.lines == [incoming("Hello."), outgoing("ja:An unfinished question is now complete.", target: japanese)],
              "only an explicit retry authorizes the later completed question to speak in its captured direction")
        subject.close()
        await settle()
    }

    static func expiredBoundTurnCannotRestart() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        send(subject, id: 2, source: "A bound old question.", language: english)
        await until("bound old request starts before context expiration") { Calls.requests.count == 1 }
        let old = subject.visibleUtterances[1]
        subject.automaticLastActivity = Date().addingTimeInterval(-601)
        send(subject, id: 3, source: "Buenos días.", language: spanish, target: english, translation: "Good morning.")
        subject.beginTranslation(old)
        Calls.complete(0)
        await settle()
        check(Calls.requests.count == 1 && old.translation.isEmpty && old.target == japanese,
              "a delayed retry callback cannot authorize new automatic work for a visible expired-session turn")
        check(!Calls.lines.contains { $0.text == "ja:A bound old question." },
              "expired-session output cannot start public playback after a new partner is discovered")
        subject.close()
        await settle()
    }

    static func rawSuffixAfterNativePartial() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "ありがとう", language: japanese, target: english,
             translation: "Thank", stable: "Thank", languageFinal: false, sourceFinal: false, closed: false)
        let row = subject.visibleUtterances[0]
        send(subject, id: 1, source: "ありがとう。", language: japanese, target: nil)
        await settle()
        check(row.target == nil && Calls.requests.isEmpty,
              "a raw-only canonical snapshot remains display-only and cannot reuse a superseded native target")
        check(row.translation.isEmpty && Calls.lines.isEmpty,
              "retraction clears an unfinished native preview without speaking it or starting Broker work")
        send(subject, id: 1, source: "ありがとう。", language: japanese, target: english, translation: "Thank you.")
        check(Calls.requests.isEmpty && Calls.lines == [incoming("Thank you.")]
              && subject.visibleUtterances.count == 1 && row.source == "ありがとう。",
              "later native completion appends on the same row without duplicate Broker work")
        subject.close()
        await settle()
    }

    static func nativeResetAndBrokerOwnership() async {
        for catchUp in [false, true] {
            Calls.reset(); Calls.automaticResponses = false
            let subject = store()
            send(subject, id: 1, source: "A question with no destination yet.", language: english)
            let waiting = subject.visibleUtterances[0]
            // Exercise recovery from stale UI bookkeeping independently of
            // the model's correct initial awaitingPartner state.
            waiting.translationState = .working
            send(subject, id: 2, source: "駅はあちらです。", language: japanese, target: english,
                 translation: "The station is over there.", languageFinal: false,
                 sourceFinal: false, closed: true, catchUp: catchUp)
            guard let native = subject.visibleUtterances.first(where: { $0.source == "駅はあちらです。" }) else {
                check(false, "the partially completed native row is visible before reset")
                return
            }
            check(native.translationState == .working && waiting.isAwaitingLanguage && waiting.target == nil,
                  "native local closure and unresolved target retain distinct unfinished states")
            subject.handle(.sessionReset)
            check(native.translationState == .current && native.translation == "The station is over there.",
                  "native reset completes accepted partial translation for live/catch-up=\(catchUp)")
            check(waiting.translationState == .awaitingPartner && waiting.target == nil
                  && subject.detectedPartnerLanguage == nil && Calls.requests.isEmpty,
                  "native reset restores an unresolved direction to waiting without a failed or guessed request")
            check(Calls.lines == [incoming("The station is over there.")],
                  "finishing native bookkeeping cannot repeat already spoken incoming translation")
            subject.hardRelease()
            check(native.translationState == .current && waiting.translationState == .awaitingPartner,
                  "retirement preserves completed native output and honest unresolved waiting state")
            subject.close()
            await settle()
        }

        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        send(subject, id: 2, source: "Please tell me which train to take.", language: english)
        await until("the outgoing text request is held before native reset") { Calls.requests.count == 1 }
        let outgoingTurn = subject.visibleUtterances[1]
        check(outgoingTurn.isTyped && outgoingTurn.translationState == .working,
              "outgoing automatic text translation owns its task independently of the native session")
        subject.handle(.sessionReset)
        check(outgoingTurn.translationState == .working && subject.translations[outgoingTurn.id] != nil,
              "a native transport reset cannot fail or release an in-flight outgoing text request")
        subject.hardRelease()
        check(outgoingTurn.translationState == .working && subject.translations[outgoingTurn.id] != nil,
              "native engine retirement cannot fail an independently owned text translation")
        Calls.complete(0)
        await until("accepted outgoing text work completes after native engine retirement") { outgoingTurn.translationState == .current }
        check(outgoingTurn.translation == "ja:Please tell me which train to take."
              && Calls.lines == [incoming("Hello."), outgoing("ja:Please tell me which train to take.", target: japanese)],
              "independent text completion remains visible and preserves its captured output exactly once")
        subject.close()
        await settle()
    }

    static func distinctSwitchEvidence() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        send(subject, id: 2, source: "La estación está allí.", language: spanish, target: english,
             translation: "The station is there.")
        check(subject.detectedPartnerLanguage == japanese,
              "a single conflicting live sentence cannot change an established partner")
        send(subject, id: 2, source: "La estación está allí.", language: spanish, target: english,
             translation: "The station is there.")
        check(subject.detectedPartnerLanguage == japanese,
              "repeated final updates for one provider row cannot count as two switch confirmations")
        send(subject, id: 3, source: "Puede esperar aquí.", language: spanish, target: english,
             translation: "You can wait here.", catchUp: true)
        check(subject.detectedPartnerLanguage == japanese,
              "coherent catch-up language remains ineligible to corroborate a live partner switch")
        send(subject, id: 4, source: "お待ちください。", language: japanese, target: english,
             translation: "Please wait.")
        send(subject, id: 5, source: "El tren sale pronto.", language: spanish, target: english,
             translation: "The train leaves soon.")
        check(subject.detectedPartnerLanguage == japanese,
              "current-partner evidence interrupts conflicting-language corroboration")
        send(subject, id: 6, source: "Suba en este tren.", language: spanish, target: english,
             translation: "Take this train.")
        check(subject.detectedPartnerLanguage == spanish,
              "two distinct consecutive live Spanish originals confirm the new partner")
        subject.close()
        await settle()
    }

    static func token(_ text: String, language: String, translated: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["text": text, "is_final": true,
            "translation_status": translated ? "translation" : (language == "en" ? "none" : "original"),
            "language": translated ? "en" : language]
        if translated { value["source_language"] = language }
        return value
    }

    static func sameEpochRepliesThroughParser() async {
        for switching in [false, true] {
            Calls.reset(); Calls.automaticResponses = false
            let subject = store()
            if switching {
                send(subject, id: -10, source: "こんにちは。", language: japanese,
                     target: english, translation: "Hello.")
                send(subject, id: -9, source: "La estación está allí.", language: spanish,
                     target: english, translation: "The station is there.")
                check(subject.detectedPartnerLanguage == japanese,
                      "the first Spanish switch evidence leaves the established target unchanged")
            }
            let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
            parser.onEvent = { subject.handle($0) }
            let code = switching ? "es" : "ja"
            let source = switching ? "Puede esperar aquí." : "駅はあちらです。"
            let translated = switching ? "You can wait here." : "The station is over there."
            let question = "Which train should I take?"
            _ = parser.receive(.json(["tokens": [token(source, language: code),
                token(translated, language: code, translated: true), token(question, language: "en")]]),
                on: .init(id: 0, isCatchUp: false))
            guard let reply = subject.visibleUtterances.first(where: { $0.source == question }) else {
                check(false, "the same-epoch listener reply is visible before the provider endpoint")
                return
            }
            check(reply.target == nil && Calls.requests.isEmpty,
                  "a provisional reply never captures an old or guessed partner destination")
            _ = parser.receive(.json(["tokens": [["text": "<end>", "is_final": true]]]),
                               on: .init(id: 0, isCatchUp: false))
            let target = switching ? spanish : japanese
            await until("the fresh same-epoch reply gets exactly one completed-source request") { Calls.requests.count == 1 }
            check(subject.detectedPartnerLanguage == target && reply.target == target,
                  "earlier foreign evidence in the same epoch sets the fresh reply's final destination")
            check(!reply.wasAwaitingPartner && !reply.suppressesAutomaticSpeech && reply.isAutomaticSourceFinal,
                  "a reply after discovery is fresh directed speech rather than silent question backfill")
            check(Calls.requests[0].text == question && Calls.requests[0].source == english
                  && Calls.requests[0].target == target,
                  "the actual parser-to-store request retains its predetermined source, target and text")
            Calls.complete(0)
            await until("the fresh same-epoch reply becomes visible") { reply.translationState == .current }
            let expectedPrefix = switching ? [incoming("Hello."), incoming("The station is there.")] : []
            check(Calls.lines == expectedPrefix + [incoming(translated), outgoing("\(target.rawValue):" + question, target: target)],
                  "same-epoch discovery speaks each incoming private line and the fresh public reply exactly once")
            subject.close()
            await settle()
        }
    }

    static func networkAndSettingsPreserveBackfillCap() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        let questions = (0..<6).map { "Earlier question \($0)." }
        for (id, question) in questions.enumerated() { send(subject, id: id, source: question, language: english) }
        let pending = subject.visibleUtterances
        send(subject, id: 10, source: "駅はこちらです。", language: japanese, target: english, translation: "The station is here.")
        await until("only three accepted backlog requests start before the path change") { Calls.requests.count == 3 }
        for index in 0..<3 { Calls.complete(index) }
        await until("the permitted three backfills finish before connectivity changes") {
            pending.suffix(3).allSatisfy { $0.translationState == .current }
        }
        send(subject, id: 11, source: "Please tell me which platform.", language: english)
        await until("the fresh directed request is in flight before losing the path") { Calls.requests.count == 4 }
        let fresh = subject.visibleUtterances.last!
        subject.changeNetwork(false)
        await settle()
        check(fresh.translationState == .waitingForNetwork && subject.translations[fresh.id] == nil,
              "an interrupted automatic request waits for the online service instead of failing into an unavailable offline pack")
        check(!subject.usesDeviceTranslation && Calls.requests.count == 4,
              "path loss cannot issue local translation requests in unrestricted automatic mode")
        check(pending.prefix(3).allSatisfy { $0.translationState == .idle && !$0.isExplicitTranslationRequest
              && $0.suppressesAutomaticSpeech && $0.wasAwaitingPartner },
              "path loss cannot activate older bound rows excluded by the backfill cap")
        Calls.complete(3)
        await settle()
        check(fresh.translation.isEmpty, "a canceled pre-disconnect response cannot publish stale text")
        subject.changeNetwork(true)
        await until("reconnection retries the interrupted fresh request once") { Calls.requests.count == 5 }
        check(Calls.requests[4].text == "Please tell me which platform." && Calls.requests[4].target == japanese,
              "reconnect resumes only eligible work in its captured direction")
        Calls.complete(4)
        await until("the resumed online request completes") { fresh.translationState == .current }
        let count = Calls.requests.count
        subject.settings.chineseScript = .traditional
        subject.offlineSpeakerDidChange()
        await settle()
        check(Calls.requests.count == count && pending.prefix(3).allSatisfy {
            $0.translationState == .idle && !$0.isExplicitTranslationRequest && $0.suppressesAutomaticSpeech
        }, "script changes preserve the neutral, silent status of excluded older questions")
        subject.settings.speechSource = .original
        subject.speechRoutingDidChange()
        await settle()
        check(Calls.requests.count == count && pending.prefix(3).allSatisfy {
            !$0.isExplicitTranslationRequest && $0.suppressesAutomaticSpeech && $0.translation.isEmpty
        }, "voice changes cannot turn old bound questions into explicit translation or speech requests")
        subject.close()
        await settle()
    }

    static func interruptedSourceRetry() async {
        for foreign in [false, true] {
            for retire in [false, true] {
              for languageFinal in [false, true] {
                Calls.reset(); Calls.automaticResponses = false
                let subject = store()
                send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
                let original = foreign ? "次の電車はいつですか？" : "When is the next train?"
                let sourceLanguage = foreign ? japanese : english
                send(subject, id: 2, source: original, language: sourceLanguage, languageFinal: languageFinal,
                     sourceFinal: false, closed: false, partnerEvidence: false)
                let row = subject.visibleUtterances.last!
                check(!row.isAutomaticSourceFinal && row.hasFinalAutomaticLanguage == languageFinal
                      && row.target == nil && Calls.requests.isEmpty,
                      "final or volatile source tokens alone neither claim provider completion nor start text translation")
                if retire { subject.hardRelease() } else { subject.handle(.sessionReset) }
                let target = foreign ? english : japanese
                check(row.target == target && row.isFinal && !row.isAutomaticSourceFinal,
                      "local retirement retains an honest source-finality distinction and a safe explicit retry direction")
                if case .failed = row.translationState {
                    check(Calls.requests.isEmpty, "interrupted source offers retry without an automatic partial-text request")
                } else { check(false, "interrupted known-language source must expose a recoverable retry state") }
                check(subject.detectedPartnerLanguage == japanese && Calls.lines == [incoming("Hello.")],
                      "interruption cannot discover a new partner or speak a partial/replayed source")
                subject.retryTranslation(row)
                await until("the user can explicitly retry the interrupted source") { Calls.requests.count == 1 }
                check(Calls.requests[0].text == original && Calls.requests[0].source == sourceLanguage
                      && Calls.requests[0].target == target,
                      "explicit retry uses the actual retained source and independently expected destination")
                Calls.complete(0)
                await until("explicitly retried interrupted source completes") { row.translationState == .current }
                check(Calls.lines.last == (foreign ? incoming("en:" + original) : outgoing("ja:" + original, target: japanese)),
                      "explicit retry preserves its predetermined synthesis language and output route")
                subject.close()
                await settle()
              }
            }
        }
    }

    static func settingsCancelBackfillHonestly() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        for id in 0..<6 { send(subject, id: id, source: "Earlier unanswered question \(id).", language: english) }
        let earlier = subject.visibleUtterances
        send(subject, id: 10, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        await until("three permitted silent backfills are held before settings change") { Calls.requests.count == 3 }
        check(earlier.suffix(3).allSatisfy { $0.translationState == .working },
              "the canceled backfills were genuinely active before the settings action")
        guard let partialRequest = Calls.requests.firstIndex(where: { $0.text == "Earlier unanswered question 3." }) else {
            check(false, "the predetermined partial backfill request exists")
            return
        }
        Calls.requests[partialRequest].continuation.yield("途中の翻訳")
        await until("one backfill has visible accepted partial output before cancellation") { earlier[3].translation == "途中の翻訳" }
        let previousText = earlier.map(\.translation)
        subject.settings.chineseScript = .traditional
        subject.offlineSpeakerDidChange()
        await settle()
        check(subject.translations.isEmpty && earlier.allSatisfy {
            if $0.translation.isEmpty { return $0.translationState == .idle }
            if case .failed = $0.translationState { return true }
            return false
        },
              "canceled silent backfills return to honest neutral state instead of permanent working dots")
        check(Calls.requests.count == 3 && earlier.allSatisfy {
            $0.target == japanese && $0.suppressesAutomaticSpeech && !$0.isExplicitTranslationRequest
        }, "settings cancellation neither expands the backfill budget nor authorizes old question speech")
        for index in 0..<3 { Calls.complete(index) }
        await settle()
        check(earlier.map(\.translation) == previousText && earlier.allSatisfy {
            if $0.translation.isEmpty { return $0.translationState == .idle }
            if case .failed = $0.translationState { return true }
            return false
        } && Calls.lines.isEmpty,
              "late canceled backfill results cannot silently republish old text or audio after settings change")
        subject.close()
        await settle()
    }

    static func lateBacklogCompletionAndPreviewRetraction() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        for id in 0..<6 {
            send(subject, id: id, source: "Unfinished earlier question \(id).", language: english,
                 sourceFinal: false, closed: false)
        }
        let earlier = subject.visibleUtterances
        send(subject, id: 10, source: "駅はこちらです。", language: japanese, target: english, translation: "The station is here.")
        check(earlier.allSatisfy { $0.target == japanese && $0.wasAwaitingPartner && $0.suppressesAutomaticSpeech },
              "even unfinished pre-discovery questions are permanently classified as silent backfill")
        for id in 0..<6 { send(subject, id: id, source: "Unfinished earlier question \(id).", language: english) }
        await settle()
        check(Calls.requests.isEmpty && earlier.allSatisfy { $0.translationState == .idle },
              "late provider completions cannot bypass the completed-question backfill budget")
        subject.close()
        await settle()

        Calls.reset(); Calls.automaticResponses = false
        let revised = store()
        send(revised, id: 20, source: "電車", language: japanese, target: english,
             translation: "Train", stable: "", languageFinal: false, sourceFinal: false, closed: false)
        let preview = revised.visibleUtterances[0]
        check(preview.translation == "Train" && preview.target == english,
              "an unconfirmed native preview can be displayed in its explicitly supplied target")
        send(revised, id: 20, source: "電車", language: japanese, target: nil,
             languageFinal: false, sourceFinal: false, closed: false)
        check(preview.translation.isEmpty && preview.translatedSource == nil && preview.translatedTarget == nil
              && preview.target == nil && preview.isSourceOnly,
              "an empty native snapshot retracts a superseded preview and its target/provenance")
        check(revised.detectedPartnerLanguage == nil && Calls.requests.isEmpty && Calls.lines.isEmpty,
              "preview retraction cannot invent partner evidence, text work or playback")
        revised.close()
        await settle()

        Calls.reset(); Calls.automaticResponses = false
        let corrected = store()
        send(corrected, id: 30, source: "電車です。", language: japanese, target: english, translation: "A train.")
        let row = corrected.visibleUtterances[0]
        send(corrected, id: 30, source: "A provisional English correction", language: english,
             languageFinal: false, sourceFinal: false, closed: false)
        check(row.sourceLanguage == english && !row.isAutomaticSourceFinal && row.target == nil
              && row.translation.isEmpty && Calls.requests.isEmpty,
              "a revised source language cannot inherit an earlier completed direction or start provisional outgoing text work")
        corrected.close()
        await settle()
    }

    static func unsupportedVoiceKeepsIncomingSpeech() async {
        Calls.reset()
        let subject = store()
        NeuralVoicePacks.shared.unavailableLanguages = [japanese.rawValue]
        defer { NeuralVoicePacks.shared.unavailableLanguages = [] }
        send(subject, id: 1, source: "こんにちは。", language: japanese, target: english, translation: "Hello.")
        send(subject, id: 2, source: "Thank you for your help.", language: english)
        let reply = subject.visibleUtterances.last!
        await until("unsupported downloaded voice does not prevent visible text translation") { reply.translationState == .current }
        send(subject, id: 3, source: "どういたしまして。", language: japanese, target: english, translation: "You are welcome.")
        check(Calls.lines == [incoming("Hello."), incoming("You are welcome.")],
              "a missing outgoing voice skips that target while supported incoming headphone speech continues")
        check(subject.settings.speaksTranslations && subject.alert == nil && reply.translation == "ja:Thank you for your help.",
              "unsupported speech does not globally disable the setting or turn a usable translation into an error popup")
        subject.close()
        await settle()
    }

    static func nativeContinuationThroughStore() async {
        for completeFirst in [false, true] {
            Calls.reset(); Calls.automaticResponses = false
            let subject = store()
            let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
            parser.onEvent = { subject.handle($0) }
            let original = "はい、あそこです。"
            let prefix = completeFirst ? "Yes, it’s right here." : "Yes, it’s"
            _ = parser.receive(.json(["tokens": [token(original, language: "ja"),
                token(prefix, language: "ja", translated: true)]]), on: .init(id: 0, isCatchUp: false))
            let first = subject.visibleUtterances[0]
            check(first.source == original && first.translation == prefix,
                  "the actual adapter's first native sentence is attached to its independent Japanese original")
            _ = parser.receive(.json(["tokens": [token("Thank you.", language: "en")]]),
                               on: .init(id: 0, isCatchUp: false))
            let lastTokens = completeFirst
                ? [token("あの角です。", language: "ja"), token("It is around the corner.", language: "ja", translated: true)]
                : [token(" right here.", language: "ja", translated: true)]
            _ = parser.receive(.json(["tokens": lastTokens]), on: .init(id: 0, isCatchUp: false))
            check(subject.visibleUtterances[0] === first && first.translation == "Yes, it’s right here.",
                  "an intervening listener original cannot detach the tail of an unfinished native sentence")
            let expectedSources = completeFirst ? [original, "Thank you.", "あの角です。"] : [original, "Thank you."]
            check(subject.visibleUtterances.map(\.source) == expectedSources,
                  "a native continuation stays on its original row while a completed later foreign answer retains a separate row")
            _ = parser.receive(.json(["tokens": [["text": "<end>", "is_final": true]]]),
                               on: .init(id: 0, isCatchUp: false))
            await until("the listener reply in the composed continuation case translates once") { Calls.requests.count == 1 }
            check(Calls.requests[0].text == "Thank you." && Calls.requests[0].source == english && Calls.requests[0].target == japanese,
                  "native ownership changes cannot alter the intervening outgoing source or destination")
            Calls.complete(0)
            await until("the composed listener reply completes") {
                subject.visibleUtterances.first(where: { $0.source == "Thank you." })?.translationState == .current
            }
            let native = completeFirst ? [incoming("Yes, it’s right here."), incoming("It is around the corner.")]
                : [incoming("Yes, it’s right here.")]
            check(Calls.lines == native + [outgoing("ja:Thank you.", target: japanese)],
                  "actual adapter-to-store playback emits full private sentences in order and one independent public reply")
            subject.close()
            await settle()
        }
    }

    static func typedQuestionsAfterOpenForeign() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        send(subject, id: 1, source: "駅はあちらです。", language: japanese,
             languageFinal: false, sourceFinal: false, closed: false)
        let questions = (0..<6).map { "Which platform does the train to the city centre leave from? Question \($0)." }
        for question in questions { subject.submitTyped(question, language: english) }
        let typed = Array(subject.visibleUtterances.dropFirst())
        check(typed.count == 6 && typed.allSatisfy { $0.isTyped && $0.sourceLanguage == english
              && $0.isAutomaticSourceFinal && $0.target == nil && $0.waitsForAutomaticPartner },
              "actual typed-language detection creates completed English questions after an unconfirmed foreign row without guessing its language")
        check(Calls.requests.isEmpty && Calls.lines.isEmpty,
              "typed questions after provisional foreign speech still wait without speculative API requests or output")
        send(subject, id: 1, source: "駅はあちらです。", language: japanese, target: english, translation: "The station is over there.")
        await until("only three completed typed questions are backfilled after first discovery") { Calls.requests.count == 3 }
        check(typed.allSatisfy { $0.target == japanese && !$0.waitsForAutomaticPartner && !$0.isAwaitingLanguage
              && $0.wasAwaitingPartner && $0.suppressesAutomaticSpeech },
              "completed typed rows after the discovering row bind silently and leave Waiting for language")
        check(Set(Calls.requests.map(\.text)) == Set(questions.suffix(3))
              && Calls.requests.allSatisfy { $0.source == english && $0.target == japanese },
              "the typed-after-foreign path preserves the same independent newest-three budget and source-to-target direction")
        for index in 0..<3 { Calls.complete(index) }
        await until("the selected typed backfills become visible") { typed.suffix(3).allSatisfy { $0.translationState == .current } }
        check(typed.prefix(3).allSatisfy { $0.translationState == .idle && $0.translation.isEmpty }
              && Calls.lines == [incoming("The station is over there.")],
              "unselected typed questions stay neutral and no completed old question speaks after its answer")
        let fresh = "Thank you for explaining the platform number."
        subject.submitTyped(fresh, language: english)
        await until("a new typed reply after discovery translates immediately") { Calls.requests.count == 4 }
        check(Calls.requests[3].text == fresh && Calls.requests[3].source == english && Calls.requests[3].target == japanese,
              "later typed speech uses the known partner without being classified as old backfill")
        Calls.complete(3)
        await until("the fresh typed reply speaks in its captured public direction") { Calls.lines.count == 2 }
        check(Calls.lines == [incoming("The station is over there."), outgoing("ja:" + fresh, target: japanese)],
              "only the fresh typed reply authorizes public speech while older typed questions remain silent")
        subject.close()
        await settle()
    }

    static func decimalContinuationThroughStore() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
        parser.onEvent = { subject.handle($0) }
        let original = "あそこまで三点一四キロです。"
        _ = parser.receive(.json(["tokens": [token(original, language: "ja"),
            token("It is 3.", language: "ja", translated: true)]]), on: .init(id: 0, isCatchUp: false))
        let first = subject.visibleUtterances[0]
        check(Calls.lines.isEmpty,
              "the actual consumer holds a terminal numeric period instead of speaking a possibly incomplete decimal")
        _ = parser.receive(.json(["tokens": [token("Can we walk there?", language: "en")]]),
                           on: .init(id: 0, isCatchUp: false))
        _ = parser.receive(.json(["tokens": [token("14 kilometres.", language: "ja", translated: true)]]),
                           on: .init(id: 0, isCatchUp: false))
        check(subject.visibleUtterances.count == 2 && subject.visibleUtterances[0] === first
              && first.source == original && first.translation == "It is 3.14 kilometres.",
              "an intervening listener source cannot split a decimal continuation into another native caption")
        check(Calls.lines == [incoming("It is 3.14 kilometres.")],
              "the composed parser and sentence consumer play the full decimal once instead of fourteen before three")
        _ = parser.receive(.json(["tokens": [["text": "<end>", "is_final": true]]]),
                           on: .init(id: 0, isCatchUp: false))
        await until("the independent decimal-case listener reply translates once") { Calls.requests.count == 1 }
        check(Calls.requests[0].text == "Can we walk there?" && Calls.requests[0].source == english
              && Calls.requests[0].target == japanese,
              "numeric incoming ownership cannot contaminate the outgoing request's language or text")
        Calls.complete(0)
        await until("the independent decimal-case listener reply speaks once") { Calls.lines.count == 2 }
        check(Calls.lines == [incoming("It is 3.14 kilometres."), outgoing("ja:Can we walk there?", target: japanese)],
              "decimal incoming playback precedes its independently routed complete public reply")
        subject.close()
        await settle()
    }

    static func heldQuestionAndQuoteThroughStore() async {
        let cases = [
            ("Is it 3?", " Yes, platform three.", "Is it 3? Yes, platform three."),
            ("“Yes.”", " said the guide.", "“Yes.” said the guide."),
        ]
        for (prefix, suffix, complete) in cases {
            Calls.reset(); Calls.automaticResponses = false
            let subject = store()
            let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
            parser.onEvent = { subject.handle($0) }
            let original = "三番ホームと案内人が言いました。"
            _ = parser.receive(.json(["tokens": [token(original, language: "ja"),
                token(prefix, language: "ja", translated: true)]]), on: .init(id: 0, isCatchUp: false))
            let first = subject.visibleUtterances[0]
            check(Calls.lines.isEmpty,
                  "the actual consumer holds a terminal digit-question or quoted terminator before its continuation")
            _ = parser.receive(.json(["tokens": [token("Thank you.", language: "en")]]),
                               on: .init(id: 0, isCatchUp: false))
            _ = parser.receive(.json(["tokens": [token(suffix, language: "ja", translated: true)]]),
                               on: .init(id: 0, isCatchUp: false))
            check(subject.visibleUtterances.count == 2 && subject.visibleUtterances[0] === first
                  && first.translation == complete && Calls.lines == [incoming(complete)],
                  "the parser shares the consumer boundary so an unsaid prefix and its tail stay ordered on the original native row")
            _ = parser.receive(.json(["tokens": [["text": "<end>", "is_final": true]]]),
                               on: .init(id: 0, isCatchUp: false))
            await until("the independent reply after held punctuation translates once") { Calls.requests.count == 1 }
            check(Calls.requests[0].text == "Thank you." && Calls.requests[0].source == english
                  && Calls.requests[0].target == japanese,
                  "punctuation-boundary handling cannot alter the intervening reply's independent direction")
            Calls.complete(0)
            await until("the independent reply after held punctuation speaks once") { Calls.lines.count == 2 }
            check(Calls.lines == [incoming(complete), outgoing("ja:Thank you.", target: japanese)],
                  "the full held native sentence plays privately before one complete public reply")
            subject.close()
            await settle()
        }
    }

    static func trailingFillerContinuationThroughStore() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = store()
        let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
        parser.onEvent = { subject.handle($0) }
        let original = "三番の部屋は左側です。"
        _ = parser.receive(.json(["tokens": [token(original, language: "ja"),
            token("Room three, um.", language: "ja", translated: true)]]), on: .init(id: 0, isCatchUp: false))
        let first = subject.visibleUtterances[0]
        check(first.translation == "Room three" && Calls.lines.isEmpty,
              "the actual consumer strips trailing hesitation before deciding whether incoming speech is complete")
        _ = parser.receive(.json(["tokens": [token("Thank you.", language: "en")]]),
                           on: .init(id: 0, isCatchUp: false))
        _ = parser.receive(.json(["tokens": [token(" is on your left.", language: "ja", translated: true)]]),
                           on: .init(id: 0, isCatchUp: false))
        check(subject.visibleUtterances.count == 2 && subject.visibleUtterances[0] === first
              && first.translation == "Room three is on your left."
              && Calls.lines == [incoming("Room three is on your left.")],
              "native splitting uses the filler-cleaned boundary so the unsaid prefix cannot be overtaken by its tail")
        _ = parser.receive(.json(["tokens": [["text": "<end>", "is_final": true]]]),
                           on: .init(id: 0, isCatchUp: false))
        await until("the independent reply after a filler-ended prefix translates once") { Calls.requests.count == 1 }
        check(Calls.requests[0].text == "Thank you." && Calls.requests[0].source == english
              && Calls.requests[0].target == japanese,
              "filler normalization preserves the intervening reply's independently expected direction")
        Calls.complete(0)
        await until("the independent reply after a filler-ended prefix speaks once") { Calls.lines.count == 2 }
        check(Calls.lines == [incoming("Room three is on your left."), outgoing("ja:Thank you.", target: japanese)],
              "one complete cleaned incoming sentence precedes one complete public reply")
        subject.close()
        await settle()
    }

    final class TimerObservation { var fired = false }

    static func deletionCancelsOldSilenceDeadline() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "A deleted partial question", language: english,
             languageFinal: false, sourceFinal: false, closed: false)
        let removed = subject.visibleUtterances[0]
        check(subject.current === removed && subject.silenceTimer != nil,
              "the deleted row actually owns an armed listening deadline")
        subject.silenceTimer?.cancel()
        let observation = TimerObservation()
        subject.silenceTimer = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            observation.fired = true
            subject.engine?.endTurn()
        }
        subject.delete(removed)
        check(subject.current == nil && subject.silenceTimer == nil && subject.visibleUtterances.isEmpty,
              "deleting the active row releases its timer ownership as well as its caption")
        // The next provider turn can begin accepting audio before its first
        // result arrives. No transcript event rearms/cancels the deadline here.
        subject.engine?.send(Data([0, 0]))
        try? await Task.sleep(for: .milliseconds(100))
        check(!observation.fired,
              "a deleted row's old deadline cannot finalize a later provider turn while its first words are still pending")
        send(subject, id: 2, source: "The next question is still open", language: english,
             languageFinal: false, sourceFinal: false, closed: false)
        check(subject.visibleUtterances.count == 1 && subject.current === subject.visibleUtterances[0]
              && !subject.visibleUtterances[0].isFinal,
              "fresh results continue as a new open row after the deleted deadline has passed")
        subject.close()
        await settle()
    }

    static func shortTypedInputKeepsReaderSide() async {
        check(Language.detect("3?", among: Language.soniox) == nil,
              "the short-input fixture actually exercises an undecidable language")
        for hint in [english, japanese, Language("und")] {
            Calls.reset()
            let subject = store()
            send(subject, id: 1, source: "こんにちは。", language: japanese,
                 target: english, translation: "Hello.")
            subject.submitTyped("3?", language: hint)
            let row = subject.visibleUtterances.last!
            let source = hint == japanese ? japanese : english
            let target = source == english ? japanese : english
            await until("short typed input requests translation for its reader side") { Calls.requests.count == 1 }
            check(row.sourceLanguage == source && row.target == target
                  && Calls.requests[0].source == source && Calls.requests[0].target == target,
                  "an undecidable typed line uses a supported near-reader hint, with listener fallback for unknown hints")
            check(subject.detectedPartnerLanguage == japanese,
                  "typed fallback cannot count as spoken partner-language evidence")
            await until("short typed translation completes") { row.translationState == .current }
            check(Calls.lines.last == (target == english
                    ? incoming("en:3?") : outgoing("ja:3?", target: japanese)),
                  "short typed lines retain the independently expected output route")
            subject.close()
            await settle()
        }
        Calls.reset()
        let subject = store()
        subject.submitTyped("これは日本語で書いた長い質問です。駅はどこですか。", language: english)
        await until("unambiguous typed Japanese overrides the English UI hint") { Calls.requests.count == 1 }
        check(Calls.requests[0].source == japanese && Calls.requests[0].target == english
              && subject.detectedPartnerLanguage == nil,
              "language recognition remains authoritative without inventing a spoken partner")
        subject.close()
        await settle()
    }

    static func explicitEditTranslatesSourceOnlyTurn() async {
        Calls.reset()
        let subject = store()
        send(subject, id: 1, source: "Buenos días.", language: spanish,
             target: english, translation: "Good morning.")
        send(subject, id: 2, source: "次の電車はいつですか。", language: japanese,
             partnerEvidence: false)
        let row = subject.visibleUtterances.last!
        check(row.isSourceOnly && row.target == nil && Calls.requests.isEmpty,
              "a completed foreign source without native translation starts honestly source-only")
        subject.edit(row, to: "次の電車は何時ですか。")
        await until("an explicit source edit starts one translation") { Calls.requests.count == 1 }
        check(row.target == english && row.sourceLanguage == japanese
              && Calls.requests[0].source == japanese && Calls.requests[0].target == english
              && Calls.requests[0].text == "次の電車は何時ですか。",
              "editing a source-only foreign turn binds the listener destination and translates the corrected words")
        check(row.isTyped && row.isExplicitTranslationRequest && row.isAutomaticSourceFinal
              && subject.detectedPartnerLanguage == spanish,
              "an explicit edit cannot bypass the two-turn spoken language rule")
        send(subject, id: 2, source: "遅い更新。", language: japanese,
             target: english, translation: "A late update.", partnerEvidence: false)
        check(row.source == "次の電車は何時ですか。",
              "late provider updates cannot overwrite the explicitly corrected source")
        await until("the corrected incoming translation becomes visible") { row.translationState == .current }
        check(Calls.lines.last == incoming("en:次の電車は何時ですか。"),
              "the explicit foreign edit is spoken only to the listener's headphones")
        let count = Calls.requests.count
        subject.edit(row, to: " \n次の電車は何時ですか。 \n")
        await settle()
        check(Calls.requests.count == count, "an unchanged trimmed edit does not issue a duplicate request")
        subject.close()
        await settle()

        Calls.reset()
        let waiting = store()
        send(waiting, id: 1, source: "An unanswered question.", language: english)
        let question = waiting.visibleUtterances[0]
        waiting.edit(question, to: "A corrected unanswered question.")
        await settle()
        check(question.target == nil && question.translationState == .awaitingPartner && Calls.requests.isEmpty,
              "editing the listener's waiting turn cannot invent a partner destination")
        waiting.close()
        await settle()
    }

    static func savedProtocolThroughStore() async {
        Calls.reset(); Calls.automaticResponses = false
        let subject = ConversationStore()
        subject.isListening = false
        subject.settings.conversationMode = .automatic
        subject.settings.speechListenerLanguage = english
        subject.settings.languages = legacy
        let parser = AutomaticSonioxTranscriber(.init(credential: .apiKey("unused-local-test"), listenerLanguage: english))
        subject.settings.pipeline = .init(engine: parser, translator: AppleTranslator(), fallbackTranslator: nil)
        subject.beginListening()
        guard CommandLine.arguments.count == 2,
              let capture = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
            check(false, "saved one-way protocol fixture is readable")
            return
        }
        for line in capture.split(separator: "\n") {
            _ = parser.receive(.string(String(line)), on: .init(id: 0, isCatchUp: false))
        }
        let rows = subject.visibleUtterances
        check(rows.count == 4, "actual automatic parser and store retain the four independent service-capture source turns")
        check(rows.map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) }
              == ["Thank you very much.", "ありがとうございます。", "Thank you very much.", "ありがとうございます。"],
              "the combined protocol path preserves independently predetermined original text")
        check(rows.map(\.sourceLanguage) == [english, japanese, english, japanese]
              && rows.map(\.target) == [japanese, english, japanese, english],
              "actual parser events discover Japanese without using the unrelated saved pair")
        check(rows[0].suppressesAutomaticSpeech && !rows[2].suppressesAutomaticSpeech,
              "the real user-first run backfills silently while later directed speech remains eligible")
        check(subject.detectedPartnerLanguage == japanese && subject.settings.languages == legacy,
              "the complete captured conversation learns its partner without rewriting preferences")
        await until("only the two actual English source turns require text translation") { Calls.requests.count == 2 }
        check(Calls.requests.allSatisfy { $0.text == "Thank you very much." && $0.source == english && $0.target == japanese },
              "actual one-way incoming speech is not redundantly sent to a guessed text-translation target")
        for index in Calls.requests.indices.reversed() { Calls.complete(index) }
        await until("both real outgoing source turns receive their own visible translations") {
            !rows[0].translation.isEmpty && !rows[2].translation.isEmpty
        }
        let expected = [incoming("Thank you very much."), incoming("Thank you very much."),
                        outgoing("ja:Thank you very much.", target: japanese)]
        let normalized = Calls.lines.map {
            Calls.Line(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), language: $0.language, output: $0.output)
        }
        check(normalized == expected,
              "actual parser-to-store output keeps two private native translations and one fresh public reply, suppressing the stale first question")
        check(rows[1].listenerText.trimmingCharacters(in: .whitespacesAndNewlines) == "Thank you very much."
              && rows[1].partnerText == "ありがとうございます。" && rows[1].text(in: spanish).isEmpty,
              "captured incoming source and translation remain on their actual language surfaces")
        subject.close()
        await settle()
    }

    static func main() async {
        modelDirections()
        await englishFirst()
        await foreignFirstAndListener()
        await boundedSilentBackfill()
        await laterPartnerAndDelayedRequests()
        await evidenceGates()
        await sourceEvidenceBeforeTranslation()
        await translationOnlyDoesNotDiscover()
        await sharedWordDoesNotSelectPartner()
        await contradictoryMetadata()
        await modeAndResetBoundaries()
        await expiredContext()
        await clearCancelsDelayedTranslation()
        await localClosureDoesNotCompleteBackfill()
        await expiredBoundTurnCannotRestart()
        await rawSuffixAfterNativePartial()
        await nativeResetAndBrokerOwnership()
        await distinctSwitchEvidence()
        await sameEpochRepliesThroughParser()
        await networkAndSettingsPreserveBackfillCap()
        await interruptedSourceRetry()
        await settingsCancelBackfillHonestly()
        await lateBacklogCompletionAndPreviewRetraction()
        await unsupportedVoiceKeepsIncomingSpeech()
        await nativeContinuationThroughStore()
        await typedQuestionsAfterOpenForeign()
        await decimalContinuationThroughStore()
        await heldQuestionAndQuoteThroughStore()
        await trailingFillerContinuationThroughStore()
        await deletionCancelsOldSilenceDeadline()
        await shortTypedInputKeepsReaderSide()
        await explicitEditTranslatesSourceOnlyTurn()
        await savedProtocolThroughStore()
        print("Automatic conversation regression: \(assertions) assertions passed")
    }
}
