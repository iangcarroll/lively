import Foundation

@main struct NativeTranslationOwnershipRegression {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    static func settle() async { for _ in 0..<500 { await Task.yield() } }
    static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        check(false, "timed out waiting for controlled text translation")
    }
    static func pipeline() -> (ConversationStore, TestEngine, TestEngine) {
        let store = ConversationStore(), cloud = TestEngine(), local = TestEngine()
        store.settings.pipeline = .init(engine: HybridSpeechEngine(local: local, cloud: cloud),
                                        translator: nil, fallbackTranslator: AppleTranslator())
        store.beginListening()
        return (store, cloud, local)
    }
    static func native(_ id: Int, text: String = "Where is the station?", translation: String = "",
                       closed: Bool = true, catchUp: Bool) -> SpeechEvent {
        .segment(.init(id: id, source: text, translation: translation, stableTranslation: translation,
                       language: .english, isClosed: closed, isCatchUp: catchUp))
    }
    static func providerSurvivesOutage(catchUp: Bool, closed: Bool) async {
        Calls.reset(); Calls.automaticResponses = false
        let (store, cloud, _) = pipeline()
        cloud.onEvent(native(10, closed: false, catchUp: catchUp))
        let turn = store.utterances[0]
        if closed { cloud.onEvent(native(10, catchUp: catchUp)) }
        await settle()
        check(Calls.requests.isEmpty, "online native segments do not start text requests")
        check(turn.needsTranslation, "missing native text remains retryable")
        let obsolete = cloud.onEvent
        store.changeNetwork(false)
        await settle()
        check(Calls.requests.isEmpty, "offline service selection does not steal native ownership")
        check(turn.translationState != .working, "interrupted native turns expose retry instead of permanent activity")
        obsolete(native(10, translation: "Must be ignored.", catchUp: catchUp))
        check(turn.translation.isEmpty, "old cloud callbacks are rejected during local recognition")
        store.changeNetwork(true)
        cloud.onEvent(native(10, translation: "駅はどこですか？", catchUp: catchUp))
        await settle()
        check(turn.translation == "駅はどこですか？" && turn.translationState == .current,
              "provider completion updates its retained row after reconnect")
        check(store.utterances.count == 1 && Calls.requests.isEmpty, "reconnect creates no competing row or request")
        check(Calls.lines == [.init(text: "駅はどこですか？", language: Language("ja"), output: .speaker)],
              "native translation plays exactly once on its captured output")
        cloud.onEvent(native(10, translation: "駅はどこですか？", catchUp: catchUp))
        await settle()
        check(Calls.lines.count == 1, "repeated native completion cannot duplicate speech")
        store.close()
    }
    static func explicitTextOwnsTurn(catchUp: Bool, edited: Bool) async {
        Calls.reset(); Calls.automaticResponses = false
        let (store, cloud, _) = pipeline()
        cloud.onEvent(native(20, catchUp: catchUp))
        let turn = store.utterances[0]
        let expected = edited ? "Where is the museum?" : "Where is the station?"
        if edited { store.edit(turn, to: expected) } else { store.retryTranslation(turn) }
        await until { Calls.requests.count == 1 }
        check(turn.isTyped && Calls.requests[0].text == expected, "retry or edit owns the current caption")
        check(Calls.requests[0].source == .english && Calls.requests[0].target == Language("ja"),
              "explicit recovery retains its direction")
        cloud.onEvent(native(20, translation: "Old translation.", catchUp: catchUp))
        check(store.utterances.count == 1 && turn.source == expected && turn.translation.isEmpty,
              "late native updates neither overwrite nor resurrect an explicit turn")
        check(Calls.lines.isEmpty, "native callbacks cannot speak after explicit text ownership")
        cloud.onEvent(native(21, text: "New words.", translation: "新しい言葉。", catchUp: catchUp))
        cloud.onEvent(native(22, text: "More words.", translation: "別の言葉。", catchUp: catchUp))
        check(turn.translationState == .working, "new segments do not abandon explicit text requests")
        cloud.onEvent(native(20, translation: "Delayed older translation.", catchUp: catchUp))
        check(store.utterances.count == 3 && turn.source == expected && turn.translation.isEmpty,
              "explicit native bindings survive newer segments")
        Calls.complete(0)
        await until { turn.translationState == .current }
        check(turn.translation == "ja:" + expected && !turn.needsTranslation, "explicit text completes normally")
        check(Calls.lines.filter { $0.text == "ja:" + expected }.count == 1, "explicit recovery plays once")
        store.close()
        check(store.segmentUtterances.isEmpty && store.catchUpUtterances.isEmpty,
              "engine retirement releases explicit native bindings")
    }
    static func localSpeechStillTranslates() async {
        Calls.reset(); Calls.automaticResponses = false
        let (store, _, local) = pipeline()
        store.changeNetwork(false)
        local.onEvent(.replaceText("Where is the platform?", .english))
        local.onEvent(.turnEnded)
        await until { Calls.requests.count == 1 }
        let turn = store.utterances[0]
        check(!turn.isTyped && !turn.usesNativeTranslation, "local recognition retains raw speech ownership")
        check(Calls.requests[0].source == .english && Calls.requests[0].target == Language("ja"),
              "offline raw speech retains the correct translation direction")
        store.changeNetwork(true)
        Calls.complete(0)
        await until { turn.translationState == .current }
        check(turn.translation == "ja:Where is the platform?" && !turn.needsTranslation,
              "raw speech translation held across reconnect still completes")
        check(Calls.lines.count == 1 && Calls.lines[0].output == .speaker, "raw recovery retains its output")
        store.close()
    }
    static func main() async {
        for catchUp in [false, true] {
            for closed in [false, true] { await providerSurvivesOutage(catchUp: catchUp, closed: closed) }
            for edited in [false, true] { await explicitTextOwnsTurn(catchUp: catchUp, edited: edited) }
        }
        await localSpeechStillTranslates()
        print("Native translation ownership: \(assertions) assertions passed")
    }
}
