import Foundation

// Translation and synthesis are deliberately controlled here. Real production
// event handling, models, translation scheduling and output selection are below.
struct SpeechProvider {
    struct Credential { let name: String }
    let id: String
    var credentials: [Credential] { [] }
    static let onDevice = Self(id: "on-device")
    static let soniox = Self(id: "soniox")
    func supports(_ pair: LanguagePair) -> Bool { true }
    func makePipeline(_ settings: AppSettings) -> Pipeline { settings.pipeline }
    struct Pipeline {
        let engine: any SpeechEngine
        let translator: (any TranslationService)?
        let fallbackTranslator: (any TranslationService)?
    }
}
enum SpeechSource { case original, downloaded }
enum NWInterface { enum InterfaceType { case wifi, cellular } }
enum ConversationMode { case automatic, pair }
final class AppSettings {
    var provider = SpeechProvider(id: "soniox")
    var providerID: String {
        get { provider.id }
        set { provider = SpeechProvider(id: newValue) }
    }
    // Classic suites exercise their existing two-language contract explicitly.
    // The automatic suite opts in without deriving any target from this pair.
    var conversationMode = ConversationMode.pair
    var usesAutomaticLanguageDetection: Bool { conversationMode == .automatic && providerID == "soniox" }
    var pipeline: SpeechProvider.Pipeline = .init(engine: HybridSpeechEngine(), translator: nil, fallbackTranslator: AppleTranslator())
    var hasCredentials = true
    var languages = LanguagePair(first: .english, second: Language("ja"))
    var chineseScript = ChineseScript.simplified
    var offlineSpokenLanguage = Language.english
    var speaksTranslations = true
    var speechSource = SpeechSource.downloaded
    var speechListenerLanguage = Language.english
}

protocol TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error>
}
enum TranslationError: Error { case injected; case onDevice(languageName: String); var isPermanent: Bool { true } }

enum Calls {
    struct Request {
        let text: String
        let source: Language
        let target: Language
        let context: [String]
        let script: ChineseScript
        let continuation: AsyncThrowingStream<String, Error>.Continuation
    }
    struct Line: Equatable {
        let text: String
        let language: Language
        let output: SpeechPlayer.Output
    }
    static var requests: [Request] = []
    static var lines: [Line] = []
    static var automaticResponses = true
    static var forbiddenCloudCalls = 0
    static var speakerStops = 0

    static func response(for request: Request) -> String {
        "\(request.target.rawValue):\(request.text)"
    }
    static func complete(_ index: Int) {
        let request = requests[index]
        request.continuation.yield(response(for: request))
        request.continuation.finish()
    }
    static func reset() {
        requests.removeAll()
        lines.removeAll()
        automaticResponses = true
        forbiddenCloudCalls = 0
        speakerStops = 0
    }
}
struct AppleTranslator: TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let request = Calls.Request(text: text, source: source, target: target,
                                    context: context.map(\.source), script: script, continuation: continuation)
        Calls.requests.append(request)
        if Calls.automaticResponses { Calls.complete(Calls.requests.count - 1) }
        return stream
    }
}
final class SpeechPlayer {
    enum Output: Equatable { case automatic, headphones, speaker }
    static let supportsDirectionalOutput = true
    func stop() {}
}
final class NeuralVoicePacks {
    struct Voice { let languageCode: String }
    enum Status { case ready, checking, missing }
    static let shared = NeuralVoicePacks()
    var isReady = true
    var status = Status.ready
    var unavailableLanguages: Set<String> = []
    func selectedVoice(for language: String) -> Voice? {
        unavailableLanguages.contains(language) ? nil : Voice(languageCode: language)
    }
}
final class NeuralSpeaker: TranslationSpeaker {
    let player = SpeechPlayer()
    var onError: (String) -> Void = { _ in }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output) {
        Calls.lines.append(.init(text: text, language: language, output: output))
    }
    func stop() { Calls.speakerStops += 1; Calls.lines.removeAll(); player.stop() }
}
final class SonioxSpeaker {
    struct Credential {}
    let player = SpeechPlayer()
    var onError: (String) -> Void = { _ in }
    init(credential: Credential) { Calls.forbiddenCloudCalls += 1 }
    static func credential(_ settings: AppSettings) -> Credential? { nil }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output) {
        Calls.forbiddenCloudCalls += 1
    }
    func stop() { player.stop() }
}

// INSERT_ACTUAL_MODELS

class TestEngine: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    var drainsTextOnPause = false
    var starts = 0, resumes = 0, stops = 0
    func start() { starts += 1 }
    func resume() { resumes += 1 }
    func stop() { stops += 1; onStatus(.idle) }
    func send(_ chunk: Data) {}
}
final class HybridSpeechEngine: TestEngine {
    enum Source { case local, cloud }
    var onSourceChange: (Source, TimeInterval) -> Void = { _, _ in }
}
final class ConversationStore {
    let settings = AppSettings()
    var languages: LanguagePair
    var configuredAutomaticMode = false
    var configuredListenerLanguage = Language.english
    var automaticSessionID = UUID()
    var automaticLastActivity = Date()
    var automaticSegmentUtterances: [Int: Utterance] = [:]
    var automaticCatchUpUtterances: [Int: Utterance] = [:]
    var detectedPartnerLanguage: Language?
    var pendingPartnerLanguage: Language?
    var pendingPartnerConfirmations = 0
    var automaticLanguageEvidence: Set<UUID> = []
    var utterances: [Utterance] = []
    var current: Utterance?
    var isListening = true, isOnline = true, isUsingOnDevice = false
    var interface: NWInterface.InterfaceType?
    var transcriberStatus = SpeechEngineStatus.idle
    var engineReleases = 0, statusRefreshes = 0
    var requestedListeningRestart = false
    var usingStopgap = false, didFallBackToOnDevice = false, engineIsStale = false
    var pendingDiscard: TimeInterval?, dropoutIndex: Int?
    var pendingDiscardCutoff: Date?
    var segmentUtterances: [Int: Utterance] = [:], catchUpUtterances: [Int: Utterance] = [:]
    var translations: [UUID: Task<Void, Never>] = [:], debounces: [UUID: Task<Void, Never>] = [:]
    var speechFlushes: [UUID: Task<Void, Never>] = [:]
    var spoken: [UUID: Int] = [:]
    var silenceTimer: Task<Void, Never>?, idleTeardown: Task<Void, Never>?
    var engine: (any SpeechEngine)?, engineProviderID: String?
    var translator: (any TranslationService)?, primaryTranslator: (any TranslationService)?, fallbackTranslator: (any TranslationService)?
    var textTranslator: any TranslationService { AppleTranslator() }
    // This harness controls service selection; the offline suite executes the
    // production online factory and restoration paths with network tripwires.
    var onlineTextTranslator: any TranslationService { primaryTranslator ?? AppleTranslator() }
    var isDemo = false
    var speaker: (any TranslationSpeaker)?, speakerSource: SpeechSource?
    var speakingSince: Date? = .distantPast
    var alert: String?
    init() {
        languages = settings.languages
        configuredAutomaticMode = settings.usesAutomaticLanguageDetection
        configuredListenerLanguage = settings.speechListenerLanguage
    }
    func setSpeaksTranslations(_ value: Bool) { settings.speaksTranslations = value }
    func beginTranslation(_ turn: Utterance) { translate(turn) }
    func beginListening() {
        // Match startListening's boundary before asynchronous mic permission.
        synchronizeLanguages()
        isListening = true
        startEngine(settings.provider)
    }
    func endListening() { isListening = false; finalizeStoppedTurn() }
    func stopListening() { if isListening { endListening() } }
    // Hold microphone permission/startup pending instead of making restart synchronous.
    func startListening() { requestedListeningRestart = true }
    func hardRelease() { isListening = false; releaseEngine() }
    var fallbackAllowed: Bool { canFallBackToOnDevice }
    func changeNetwork(_ online: Bool) { setPath(online: online, interface: .wifi) }
    var usesDeviceTranslation: Bool { usesOnDeviceServices }
    func refreshStatus() { statusRefreshes += 1 }
    func fallBackToOnDevice(reason: String) { fatalError("unexpected fixed-language fallback while online") }
    func prepare() -> HybridSpeechEngine {
        let hybrid = HybridSpeechEngine()
        settings.pipeline = .init(engine: hybrid, translator: AppleTranslator(), fallbackTranslator: nil)
        _ = makeEngine(settings.provider)
        return hybrid
    }
    func prepareNative() -> HybridSpeechEngine {
        let hybrid = HybridSpeechEngine()
        settings.pipeline = .init(engine: hybrid, translator: nil, fallbackTranslator: nil)
        _ = makeEngine(settings.provider)
        return hybrid
    }
    func close() {
        isListening = false
        releaseEngine()
        silenceTimer?.cancel()
        debounces.values.forEach { $0.cancel() }
        translations.values.forEach { $0.cancel() }
        speechFlushes.values.forEach { $0.cancel() }
    }
    // INSERT_ACTUAL_STORE_METHODS
}
private extension String {
    func trimmingLeadingWhitespace() -> String { String(drop(while: \.isWhitespace)) }
}
// END_SHARED_STORE_HARNESS

@main struct Regression {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { print("FAIL: " + message); exit(1) }
    }
    static func drain() async { for _ in 0..<300 { await Task.yield() } }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        check(false, "timed out waiting for controlled translation")
    }

    static func languageChangesBeforeStart() async {
        Calls.reset()
        let changed = ConversationStore()
        changed.isListening = false
        let spanish = Language("es"), french = Language("fr")
        let newPair = LanguagePair(first: spanish, second: french)
        changed.settings.languages = newPair
        changed.settings.speechListenerLanguage = french
        changed.beginListening()
        changed.engine?.onEvent(.segment(.init(id: 90, source: "¿Dónde está la estación?",
            translation: "Où est la gare ?", stableTranslation: "Où est la gare ?",
            language: spanish, isClosed: true)))
        check(changed.utterances.count == 1 && changed.utterances[0].languages == newPair,
              "onboarding pair change reaches new turns without closing Settings")
        check(changed.utterances[0].language == spanish && changed.utterances[0].target == french,
              "correct service tag is accepted in the newly selected pair")
        check(Calls.lines == [.init(text: "Où est la gare ?", language: french, output: .headphones)],
              "new-pair translation is spoken to its configured listener")
        changed.close()

        Calls.reset()
        let swapped = ConversationStore()
        swapped.isListening = false
        let oldWarm = swapped.prepare()
        let replacement = HybridSpeechEngine()
        let reversed = LanguagePair(first: Language("ja"), second: .english)
        swapped.settings.languages = reversed
        swapped.settings.pipeline = .init(engine: replacement, translator: nil, fallbackTranslator: nil)
        swapped.beginListening()
        check(swapped.engine === replacement && oldWarm.stops == 1 && oldWarm.resumes == 0,
              "pair change invalidates a prewarmed engine before the first tap")
        replacement.onEvent(.segment(.init(id: 91, source: "駅はどこですか？",
            translation: "Where is the station?", stableTranslation: "Where is the station?",
            language: Language("ja"), isClosed: true)))
        check(swapped.utterances.first?.languages == reversed,
              "swapped onboarding pair preserves the new transcript column order")
        swapped.close()
        await drain()
    }

    static func missingSegmentTranslation() async {
        for startsAnotherSegment in [false, true] {
            Calls.reset(); Calls.automaticResponses = false
            let missing = ConversationStore()
            missing.settings.speaksTranslations = false
            missing.handle(.segment(.init(id: 110, source: "Which platform is the train on?",
                translation: "", stableTranslation: "", language: .english, isClosed: true)))
            let lost = missing.utterances[0]
            if startsAnotherSegment {
                missing.handle(.segment(.init(id: 111, source: "The train is late.", translation: "電車が遅れています。",
                    stableTranslation: "電車が遅れています。", language: .english, isClosed: true)))
                missing.handle(.segment(.init(id: 112, source: "We can wait here.", translation: "ここで待てます。",
                    stableTranslation: "ここで待てます。", language: .english, isClosed: true)))
            }
            check(lost.translation.isEmpty && lost.translationState != .current,
                  "a source-only segment stays recoverable before and after the next segment")
            missing.handle(.sessionReset)
            if case .failed = lost.translationState { missing.retryTranslation(lost) }
            await until { Calls.requests.count == 1 }
            check(Calls.requests[0].text == "Which platform is the train on?"
                  && Calls.requests[0].source == .english && Calls.requests[0].target == Language("ja"),
                  "lost native translation offers a working text fallback or retry in the correct direction")
            Calls.complete(0)
            await until { lost.translationState == .current }
            check(!lost.translation.isEmpty && !lost.needsTranslation && lost.isFinal,
                  "reset cannot strand a source-only segment behind permanent typing dots")
            missing.close()
        }
        await drain()
    }

    static func catchUpStartsAtCurrentListen() async {
        for warm in [false, true] {
            Calls.reset()
            let startup = ConversationStore()
            startup.isListening = false
            let first = Utterance(source: "Earlier conversation", language: .english, languages: startup.languages)
            let second = Utterance(source: "Another earlier turn", language: .english, languages: startup.languages)
            first.isFinal = true; second.isFinal = true
            startup.utterances = [first, second]
            startup.dropoutIndex = 0 // A prior session's dropout is no longer the insertion point.
            if warm { _ = startup.prepare() }
            startup.beginListening()
            startup.handle(.segment(.init(id: 120, source: "Newer live words", translation: "新しい言葉。",
                stableTranslation: "新しい言葉。", language: .english, isClosed: true)))
            startup.handle(.segment(.init(id: 121, source: "Opening buffered words", translation: "最初の言葉。",
                stableTranslation: "最初の言葉。", language: .english, isClosed: true, isCatchUp: true)))
            startup.handle(.segment(.init(id: 122, source: "More buffered words", translation: "次の言葉。",
                stableTranslation: "次の言葉。", language: .english, isClosed: true, isCatchUp: true)))
            check(startup.utterances.map(\.source) == [first.source, second.source,
                "Opening buffered words", "More buffered words", "Newer live words"],
                "\(warm ? "warm" : "cold") startup catch-up inserts at this listen's start without a reset event")
            check(startup.dropoutIndex == 4, "catch-up insertion advances from the fresh listen position")
            startup.close()
        }
        await drain()
    }

    static func replayCutoffSurvivesResponseDelay() async {
        Calls.reset()
        let replay = ConversationStore()
        let replayEngine = replay.prepare()
        let history = Utterance(source: "Permanent history", language: .english, languages: replay.languages)
        let older = Utterance(source: "Older local words outside the replay", language: .english, languages: replay.languages)
        older.isProvisional = true
        try? await Task.sleep(for: .milliseconds(300))
        let matching = Utterance(source: "Local words whose audio was replayed", language: .english, languages: replay.languages)
        matching.isProvisional = true
        replay.utterances = [history, older, matching]
        replay.dropoutIndex = 3
        replayEngine.onSourceChange(.cloud, 0.2)
        try? await Task.sleep(for: .milliseconds(350)) // Longer than the replay window, after the source switch.
        replay.handle(.segment(.init(id: 130, source: "First delayed live cloud response", translation: "クラウドの応答。",
            stableTranslation: "クラウドの応答。", language: .english, isClosed: true)))
        check(replay.utterances.contains { $0 === older } && !replay.utterances.contains { $0 === matching },
              "delayed cloud response replaces the fixed replay window while retaining older local history")
        check(replay.dropoutIndex == 2, "removing replayed local turns adjusts the pending catch-up position")
        replay.handle(.segment(.init(id: 131, source: "Replayed opening words", translation: "再生された言葉。",
            stableTranslation: "再生された言葉。", language: .english, isClosed: true, isCatchUp: true)))
        check(replay.utterances.map(\.source) == [history.source, older.source,
            "Replayed opening words", "First delayed live cloud response"],
            "catch-up replaces local text ahead of newer live words after a delayed first response")
        replay.close()
        await drain()
    }

    static func fillerCanBecomeVisibleAfterStop() async {
        Calls.reset()
        let filler = ConversationStore()
        filler.handle(.segment(.init(id: 140, source: "Um", translation: "", stableTranslation: "",
            language: .english, isClosed: false)))
        filler.endListening()
        check(filler.visibleUtterances.isEmpty, "Stop omits a turn containing only filler")
        let final = SpeechSegment(id: 140, source: "Um, where is the station?", translation: "駅はどこですか？",
            stableTranslation: "駅はどこですか？", language: .english, isClosed: true)
        filler.handle(.segment(final))
        filler.handle(.segment(final))
        check(filler.visibleUtterances.count == 1 && filler.visibleUtterances[0].trimmedSource == "Where is the station?",
              "late nonempty final revives an omitted filler turn exactly once")
        check(filler.visibleUtterances[0].isFinal && filler.visibleUtterances[0].translation == "駅はどこですか？",
              "revived filler turn keeps its final translation")
        filler.close()
        await drain()
    }

    static func nativeSegmentsRetireWithEngine() async {
        for catchUp in [false, true] {
            for hardRelease in [false, true] {
                Calls.reset()
                let store = ConversationStore()
                let old = store.prepareNative()
                old.onEvent(.segment(.init(id: 0, source: "Original words", translation: "元の言葉。",
                    stableTranslation: "元の言葉。", language: .english, isClosed: true, isCatchUp: catchUp)))
                let original = store.utterances[0]
                let fresh: HybridSpeechEngine
                if hardRelease {
                    store.hardRelease()
                    fresh = store.prepareNative()
                } else {
                    fresh = HybridSpeechEngine()
                    store.settings.pipeline = .init(engine: fresh, translator: nil, fallbackTranslator: nil)
                    store.engineIsStale = true
                    store.beginListening()
                }
                fresh.onEvent(.segment(.init(id: 0, source: "新しい言葉。", translation: "New words.",
                    stableTranslation: "New words.", language: Language("ja"), isClosed: true, isCatchUp: catchUp)))
                check(store.utterances.count == 2 && store.utterances[0] === original
                      && original.source == "Original words" && original.translation == "元の言葉。",
                      "reused \(catchUp ? "catch-up" : "live") id after \(hardRelease ? "hard release" : "replacement") cannot overwrite history")
                check(store.utterances[1].source == "新しい言葉。" && store.utterances[1].language == Language("ja"),
                      "a fresh engine's id zero appends a new correctly labelled turn")
                old.onEvent(.segment(.init(id: 0, source: "Obsolete callback", translation: "Must not appear.",
                    stableTranslation: "Must not appear.", language: .english, isClosed: true, isCatchUp: catchUp)))
                check(store.utterances.count == 2 && original.source == "Original words"
                      && store.utterances[1].source == "新しい言葉。",
                      "retired engine callbacks cannot revise either generation's transcript")
                store.close()
            }
        }

        Calls.reset(); Calls.automaticResponses = false
        let hidden = ConversationStore()
        let old = hidden.prepareNative()
        old.onEvent(.segment(.init(id: 0, source: "Um", translation: "", stableTranslation: "",
            language: .english, isClosed: false)))
        old.onEvent(.segment(.init(id: 1, source: "Preserved history", translation: "履歴。",
            stableTranslation: "履歴。", language: .english, isClosed: true)))
        old.onEvent(.segment(.init(id: 2, source: "More preserved history", translation: "別の履歴。",
            stableTranslation: "別の履歴。", language: .english, isClosed: true)))
        old.onEvent(.segment(.init(id: 3, source: "Please translate this", translation: "",
            stableTranslation: "", language: .english, isClosed: false)))
        let pending = hidden.utterances[3]
        old.onEvent(.segment(.init(id: 4, source: "Uh", translation: "", stableTranslation: "",
            language: .english, isClosed: false, isCatchUp: true)))
        hidden.dropoutIndex = 5
        hidden.hardRelease()
        check(hidden.utterances.map(\.source) == ["Preserved history", "More preserved history", "Please translate this"]
              && hidden.segmentUtterances.isEmpty && hidden.catchUpUtterances.isEmpty,
              "hard release retires hidden objects, including a filler already pruned from the native map")
        check(hidden.dropoutIndex == 3 && hidden.current == nil,
              "retiring hidden rows adjusts the insertion position and detaches the old current turn")
        if case .failed = pending.translationState {
            check(pending.isFinal && pending.needsTranslation, "unfinished native translation becomes a final retryable turn")
        } else {
            check(false, "hard release must settle an unfinished native translation")
        }
        hidden.retryTranslation(pending)
        await until { Calls.requests.count == 1 }
        Calls.complete(0)
        await until { pending.translationState == .current }
        check(!pending.needsTranslation && !pending.translation.isEmpty, "retired native turn still supports text retry")
        hidden.close()

        for catchUp in [false, true] {
            Calls.reset()
            let deleted = ConversationStore()
            let old = deleted.prepareNative()
            old.onEvent(.segment(.init(id: 0, source: "Deleted words", translation: "削除する言葉。",
                stableTranslation: "削除する言葉。", language: .english, isClosed: true, isCatchUp: catchUp)))
            let removed = deleted.utterances[0]
            deleted.delete(removed)
            old.onEvent(.segment(.init(id: 0, source: "Late update to deleted words", translation: "遅い更新。",
                stableTranslation: "遅い更新。", language: .english, isClosed: true, isCatchUp: catchUp)))
            check(deleted.visibleUtterances.isEmpty, "explicit deletion stays suppressed within the same engine")
            deleted.hardRelease()
            let fresh = deleted.prepareNative()
            fresh.onEvent(.segment(.init(id: 0, source: "Fresh words", translation: "新しい言葉。",
                stableTranslation: "新しい言葉。", language: .english, isClosed: true, isCatchUp: catchUp)))
            check(deleted.visibleUtterances.count == 1 && deleted.visibleUtterances[0] !== removed
                  && deleted.visibleUtterances[0].source == "Fresh words",
                  "a new engine's reused id is independent of an old deletion")
            deleted.close()
        }

        Calls.reset()
        let warm = ConversationStore()
        let same = warm.prepareNative()
        same.onEvent(.segment(.init(id: 0, source: "A warm turn", translation: "同じ会話。",
            stableTranslation: "同じ会話。", language: .english, isClosed: false)))
        let original = warm.utterances[0]
        warm.endListening()
        warm.beginListening()
        same.onEvent(.segment(.init(id: 0, source: "A warm turn continued", translation: "同じ会話の続き。",
            stableTranslation: "同じ会話の続き。", language: .english, isClosed: true)))
        check(warm.utterances.count == 1 && warm.utterances[0] === original
              && original.source == "A warm turn continued",
              "warm resume keeps the same engine's native mapping instead of duplicating its turn")
        warm.close()
        await drain()
    }
    static func nativeFlushAllowsFinalSuffix() async {
        Calls.reset()
        let native = ConversationStore()
        let ja = Language("ja")
        native.handle(.segment(.init(id: 150, source: "Which platform is it?", translation: "何番線",
            stableTranslation: "何番線", language: .english, isClosed: true)))
        native.handle(.segment(.init(id: 151, source: "何番線ですか？", translation: "Which platform",
            stableTranslation: "Which platform", language: ja, isClosed: true)))
        try? await Task.sleep(for: .milliseconds(1_650))
        await until { Calls.lines.count == 2 }
        check(Calls.lines.filter { $0.language == ja } == [.init(text: "何番線", language: ja, output: .speaker)],
              "native unpunctuated prefix flushes once to the phone speaker")
        check(Calls.lines.filter { $0.language == .english } == [.init(text: "Which platform", language: .english, output: .headphones)],
              "native incoming prefix flushes once to headphones")
        let outgoing = SpeechSegment(id: 150, source: "Which platform is it?", translation: "何番線ですか？",
            stableTranslation: "何番線ですか？", language: .english, isClosed: true)
        let incoming = SpeechSegment(id: 151, source: "何番線ですか？", translation: "Which platform is it?",
            stableTranslation: "Which platform is it?", language: ja, isClosed: true)
        native.handle(.segment(outgoing))
        native.handle(.segment(incoming))
        check(Calls.lines.filter { $0.language == ja } == [
            .init(text: "何番線", language: ja, output: .speaker), .init(text: "ですか？", language: ja, output: .speaker)],
              "late native outgoing suffix remains audible after an earlier tail flush")
        check(Calls.lines.filter { $0.language == .english } == [
            .init(text: "Which platform", language: .english, output: .headphones),
            .init(text: " is it?", language: .english, output: .headphones)],
              "late native incoming suffix plays once on the original headphone route")
        native.handle(.segment(outgoing))
        native.handle(.segment(incoming))
        check(Calls.lines.count == 4, "repeated final native updates cannot replay a spoken prefix or suffix")
        native.close()

        Calls.reset()
        let raw = ConversationStore()
        raw.translator = AppleTranslator()
        raw.handle(.text("A complete raw turn."))
        let turn = raw.utterances[0]
        raw.handle(.turnEnded)
        await until { turn.translationState == .current }
        check(raw.spoken[turn.id] == Int.max && Calls.lines.count == 1,
              "completed raw translation keeps its existing sealed playback behavior")
        raw.close()
        await drain()
    }

    static func settingsRestartPreservesPendingTranslation() async {
        for changesProvider in [false, true] {
            Calls.reset(); Calls.automaticResponses = false
            let store = ConversationStore()
            store.settings.provider = changesProvider ? SpeechProvider(id: "voxtral") : .onDevice
            store.isUsingOnDevice = !changesProvider
            store.translator = AppleTranslator()
            store.handle(.replaceText("Where is the station?", .english))
            let turn = store.utterances[0]
            store.beginTranslation(turn)
            await until { Calls.requests.count == 1 }
            if changesProvider {
                store.settings.provider = SpeechProvider(id: "soniox")
            } else {
                store.settings.offlineSpokenLanguage = Language("ja")
            }
            store.settings.chineseScript = .traditional
            store.offlineSpeakerDidChange()
            await until { Calls.requests.count == 2 }
            check(store.requestedListeningRestart && store.engine == nil,
                  "settings change retries accepted text while microphone/engine restart is still pending")
            check(Calls.requests[1].text == "Where is the station?"
                  && Calls.requests[1].source == .english && Calls.requests[1].target == Language("ja")
                  && Calls.requests[1].script == .traditional,
                  "\(changesProvider ? "provider" : "input") change preserves the turn's direction and uses current script settings")
            Calls.complete(0)
            Calls.complete(1)
            await until { turn.translationState == .current }
            check(turn.isFinal && !turn.needsTranslation && turn.translatedLanguage == .english
                  && Calls.requests.count == 2,
                  "cancelled pre-settings result cannot strand or overwrite the restarted translation")
            store.close()
        }
        await drain()
    }

    static func previewRetractionAllowsFinalRevival() async {
        for catchUp in [false, true] {
            Calls.reset()
            let store = ConversationStore()
            store.handle(.segment(.init(id: 160, source: "Unconfirmed words", translation: "",
                stableTranslation: "", language: .english, isClosed: false, isCatchUp: catchUp)))
            let preview = store.utterances[0]
            check(store.visibleUtterances.count == 1, "native preview initially appears")
            let retraction = SpeechSegment(id: 160, source: "", translation: "", stableTranslation: "",
                language: .english, isClosed: true, isCatchUp: catchUp)
            store.handle(.segment(retraction))
            check(store.visibleUtterances.isEmpty, "empty closed correction retracts the provisional display")
            let final = SpeechSegment(id: 160, source: "Confirmed final words", translation: "確定した言葉。",
                stableTranslation: "確定した言葉。", language: .english, isClosed: true, isCatchUp: catchUp)
            store.handle(.segment(final))
            check(store.visibleUtterances.count == 1 && store.visibleUtterances[0] === preview
                  && preview.source == "Confirmed final words", "same-ID final revives a retracted preview")
            store.handle(.segment(final))
            check(store.visibleUtterances.count == 1, "repeated revived final remains a single turn")
            store.delete(preview)
            store.handle(.segment(retraction))
            store.handle(.segment(final))
            check(store.visibleUtterances.isEmpty, "preview revival never resurrects an explicit deletion")
            store.close()
        }
        await drain()
    }

    static func translationOnlyNativeSegments() async {
        for catchUp in [false, true] {
            for language in [Language.english, Language("ja")] {
                Calls.reset()
                let store = ConversationStore()
                let target = store.languages.other(than: language)
                let text = language == .english ? "駅はこちらです。" : "The station is here."
                let output: SpeechPlayer.Output = language == .english ? .speaker : .headphones
                let translated = SpeechSegment(id: 170, source: "", translation: text, stableTranslation: text,
                    language: language, isClosed: true, isCatchUp: catchUp)
                store.handle(.segment(translated))
                check(store.visibleUtterances.count == 1, "confirmed translation-only \(catchUp ? "catch-up" : "live") turn is visible")
                let turn = store.visibleUtterances[0]
                check(turn.source.isEmpty && turn.trimmedSource.isEmpty && turn.isTranslationOnly && turn.language == language
                      && turn.isFinal && turn.translationState == .current && !turn.needsTranslation,
                      "translation-only turn has no invented source and settles its confirmed direction")
                check(Calls.lines == [.init(text: text, language: target, output: output)],
                      "translation-only speech uses its confirmed target and listener output")
                store.handle(.segment(.init(id: 170, source: "", translation: "", stableTranslation: "",
                    language: language, isClosed: true, isCatchUp: catchUp)))
                check(store.visibleUtterances.isEmpty && !turn.isTranslationOnly, "empty correction still retracts a translation-only turn")
                store.handle(.segment(translated))
                check(store.visibleUtterances.count == 1 && store.visibleUtterances[0] === turn && Calls.lines.count == 1,
                      "same-ID translation-only restoration neither duplicates the row nor repeats stable speech")
                let source = language == .english ? "The station is here." : "駅はこちらです。"
                store.handle(.segment(.init(id: 170, source: source, translation: text, stableTranslation: text,
                    language: language, isClosed: true, isCatchUp: catchUp)))
                check(store.visibleUtterances.count == 1 && store.visibleUtterances[0] === turn
                      && turn.source == source && !turn.isTranslationOnly && Calls.lines.count == 1,
                      "later source ownership fills the same turn without replaying its translation")
                store.delete(turn)
                store.handle(.segment(translated))
                check(store.visibleUtterances.isEmpty && Calls.lines.count == 1,
                      "translation-only updates cannot resurrect a deleted turn or its speech")
                store.close()
            }
        }

        Calls.reset()
        let filler = ConversationStore()
        filler.handle(.segment(.init(id: 171, source: "Um", translation: "こんにちは。", stableTranslation: "こんにちは。",
            language: .english, isClosed: true)))
        check(filler.visibleUtterances.isEmpty && Calls.lines.isEmpty,
              "nonempty raw filler remains hidden even when a translation is present")
        filler.close()
        let unknown = ConversationStore()
        for catchUp in [false, true] {
            for language in [nil, Language("fr")] as [Language?] {
                unknown.handle(.segment(.init(id: 172, source: "", translation: "Unowned translation.",
                    stableTranslation: "Unowned translation.", language: language, isClosed: true, isCatchUp: catchUp)))
            }
        }
        check(unknown.visibleUtterances.isEmpty && Calls.lines.isEmpty,
              "translation-only text requires an explicit confirmed language within the selected pair")
        unknown.close()
        Calls.reset(); Calls.automaticResponses = false
        let raw = ConversationStore()
        raw.translator = AppleTranslator()
        raw.handle(.replaceText("Words later withdrawn", .english))
        let stale = raw.utterances[0]
        raw.beginTranslation(stale)
        await until { Calls.requests.count == 1 }
        raw.handle(.replaceText("", .english))
        Calls.complete(0)
        await until { !stale.translation.isEmpty }
        check(stale.source.isEmpty && !stale.isTranslationOnly && raw.visibleUtterances.isEmpty,
              "a raw source retraction stays hidden when an old translation request completes")
        raw.close()
        await drain()
    }

    static func main() async {
        if let selected = CommandLine.arguments.dropFirst().first {
            switch selected {
            case "pair": await languageChangesBeforeStart()
            case "missing": await missingSegmentTranslation()
            case "catch-up": await catchUpStartsAtCurrentListen()
            case "replay-cutoff": await replayCutoffSurvivesResponseDelay()
            case "filler": await fillerCanBecomeVisibleAfterStop()
            case "engine-retirement": await nativeSegmentsRetireWithEngine()
            case "native-flush": await nativeFlushAllowsFinalSuffix()
            case "settings-restart": await settingsRestartPreservesPendingTranslation()
            case "preview-retraction": await previewRetractionAllowsFinalRevival()
            case "translation-only": await translationOnlyNativeSegments()
            default: fatalError("Unknown regression scenario")
            }
            print("Online conversation \(selected): \(assertions) assertions passed")
            return
        }
        Calls.reset()
        let store = ConversationStore()
        let warm = store.prepare()
        check(!store.isUsingOnDevice && !store.usingStopgap, "online construction selects cloud")
        check(store.translator != nil, "online construction chooses cloud translator")
        store.beginListening()
        check(store.engine === warm && warm.resumes == 1 && warm.starts == 0 && warm.stops == 0,
              "first tap reuses prewarmed hybrid")
        warm.onSourceChange(.local, 0)
        check(store.isUsingOnDevice && store.usingStopgap && store.translator == nil, "local source selects fallback")
        warm.onSourceChange(.cloud, 1)
        check(!store.isUsingOnDevice && !store.usingStopgap && store.translator != nil, "reconnect selects cloud")
        let oldEvent = warm.onEvent, oldStatus = warm.onStatus, oldSource = warm.onSourceChange
        let replacement = store.prepare()
        oldEvent(.replaceText("Must never appear", .english))
        oldStatus(.failed("Obsolete failure"))
        oldSource(.local, 100)
        check(store.utterances.isEmpty && store.engine === replacement && !store.isUsingOnDevice,
              "obsolete engine cannot write text, fail or relabel source")
        check(!store.fallbackAllowed, "online failures cannot silently force a fixed language")
        store.isOnline = false
        check(store.fallbackAllowed, "actual path loss allows local fallback")
        store.isOnline = true
        let ja = Language("ja")
        for (index, language) in [Language.english, ja, Language.english, ja].enumerated() {
            let source = language == .english ? "Where is the station?" : "駅はどこですか？"
            let translation = language == .english ? "駅はどこですか？" : "Where is the station?"
            store.handle(.segment(.init(id: index, source: source, translation: translation,
                stableTranslation: translation, language: language, isClosed: true)))
        }
        check(store.utterances.map(\.language) == [.english, ja, .english, ja], "continuous switches retain correct transcript side")
        check(store.utterances.map(\.target) == [ja, .english, ja, .english], "continuous switches retain correct translation direction")
        check(Calls.lines.map(\.output) == [.speaker, .headphones, .speaker, .headphones], "both spoken directions use correct output")
        store.handle(.segment(.init(id: 10, source: "東京", translation: "Tokyo", stableTranslation: "", language: .english, isClosed: false)))
        let otherQueuedLines = Calls.lines
        let priorStops = Calls.speakerStops
        store.handle(.segment(.init(id: 10, source: "東京", translation: "Tokyo", stableTranslation: "", language: ja, isClosed: true)))
        check(store.utterances.last?.language == ja && store.utterances.last?.target == .english,
              "revised service label updates an existing turn's side and target")
        check(Calls.speakerStops == priorStops && Calls.lines.starts(with: otherQueuedLines),
              "correcting one label preserves other turns' queued speech")
        store.close()

        let revised = Utterance(source: "Tokyo", language: .english, languages: .init(first: .english, second: ja))
        revised.translation = "東京"
        revised.translatedSource = revised.trimmedSource
        revised.translatedLanguage = .english
        check(!revised.needsTranslation, "matching source and language are current")
        revised.setSource("Tokyo", language: ja)
        check(revised.needsTranslation && revised.translation.isEmpty, "identical words with corrected language invalidate translation")
        revised.setSource("Hello there", language: Language("fr"))
        check(revised.languages.contains(revised.language), "out-of-pair label cannot create a third transcript side")

        Calls.reset(); Calls.automaticResponses = false
        let streaming = ConversationStore()
        streaming.translator = AppleTranslator()
        let turn = Utterance(source: "Tokyo", language: .english, languages: streaming.languages)
        streaming.utterances = [turn]
        streaming.beginTranslation(turn)
        await until { Calls.requests.count == 1 }
        turn.setSource("Tokyo", language: ja)
        Calls.complete(0)
        await until { Calls.requests.count == 2 }
        check(turn.translation.isEmpty && Calls.requests[1].source == ja && Calls.requests[1].target == .english,
              "old-language streamed result is discarded and translation restarts in correct direction")
        Calls.complete(1)
        await until { turn.translationState == .current }
        check(turn.translatedLanguage == ja && !turn.needsTranslation, "corrected direction completes normally")
        streaming.close()
        Calls.reset(); Calls.automaticResponses = false
        let failedDirection = ConversationStore()
        failedDirection.translator = AppleTranslator()
        let corrected = Utterance(source: "Tokyo", language: .english, languages: failedDirection.languages)
        failedDirection.utterances = [corrected]
        failedDirection.beginTranslation(corrected)
        await until { Calls.requests.count == 1 }
        corrected.setSource("Tokyo", language: ja)
        Calls.requests[0].continuation.finish(throwing: TranslationError.injected)
        await until { Calls.requests.count == 2 }
        check(Calls.requests[1].source == ja && corrected.translationState == .working,
              "a failed old-direction request restarts after label correction")
        Calls.complete(1)
        await until { corrected.translationState == .current }
        failedDirection.close()

        Calls.reset(); Calls.automaticResponses = false
        let stalled = ConversationStore()
        stalled.translator = AppleTranslator()
        stalled.handle(.replaceText("Tokyo", .english))
        let stalledTurn = stalled.utterances[0]
        stalled.beginTranslation(stalledTurn)
        await until { Calls.requests.count == 1 }
        stalled.handle(.replaceText("Tokyo", ja))
        await until { Calls.requests.count == 2 }
        check(Calls.requests[1].source == ja && Calls.requests[1].target == .english,
              "correction cancels a stalled request without waiting for any old result")
        Calls.complete(0)
        Calls.complete(1)
        await until { stalledTurn.translationState == .current }
        check(stalledTurn.translatedLanguage == ja, "cancelled old request cannot overwrite the corrected result")
        stalled.close()

        Calls.reset()
        let tail = ConversationStore()
        let rawEngine = TestEngine()
        rawEngine.drainsTextOnPause = true
        tail.engine = rawEngine
        tail.translator = AppleTranslator()
        tail.handle(.text("Where is"))
        let originalTurn = tail.utterances[0]
        tail.endListening()
        check(tail.current === originalTurn && !originalTurn.isFinal, "Stop retains a raw turn while its accepted audio drains")
        tail.handle(.text(" the station?"))
        tail.handle(.turnEnded)
        await until { originalTurn.isFinal }
        check(tail.utterances.count == 1 && originalTurn.source == "Where is the station?",
              "late final words stay in their original turn after Stop")
        tail.close()

        let replay = ConversationStore()
        let replayCloud = replay.prepare()
        let local = Utterance(source: "A provisional local turn", language: .english, languages: replay.languages)
        local.isProvisional = true
        replay.utterances = [local]
        replayCloud.onSourceChange(.cloud, 30)
        replay.handle(.text("Hi"))
        replay.handle(.turnEnded)
        check(replay.utterances.count == 1 && replay.utterances[0].source == "Hi",
              "a completed short cloud turn replaces replayed local text after reconnect")
        replay.close()
        let segmentReplay = ConversationStore()
        let segmentCloud = segmentReplay.prepare()
        let localSegment = Utterance(source: "A provisional local turn", language: .english, languages: segmentReplay.languages)
        localSegment.isProvisional = true
        segmentReplay.utterances = [localSegment]
        segmentCloud.onSourceChange(.cloud, 30)
        segmentReplay.handle(.segment(.init(id: 1, source: "Hi", translation: "やあ", stableTranslation: "やあ", language: .english, isClosed: true)))
        check(segmentReplay.utterances.count == 1 && segmentReplay.utterances[0].source == "Hi",
              "a completed short native-translation segment replaces replayed local text")
        segmentReplay.close()
        await drain()
        await languageChangesBeforeStart()
        await missingSegmentTranslation()
        await catchUpStartsAtCurrentListen()
        await replayCutoffSurvivesResponseDelay()
        await fillerCanBecomeVisibleAfterStop()
        await nativeSegmentsRetireWithEngine()
        await nativeFlushAllowsFinalSuffix()
        await settingsRestartPreservesPendingTranslation()
        await previewRetractionAllowsFinalRevival()
        await translationOnlyNativeSegments()
        print("Online conversation regression: \(assertions) assertions passed")
    }
}
