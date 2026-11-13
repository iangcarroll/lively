import Foundation

enum Filler { static func strip(_ text: String, in language: Language) -> String { text } }
struct SpeechProvider {
    let id: String
    static let onDevice = Self(id: "on-device")
}
enum ProviderCredential { case mistral }
enum SpeechVoice { case original, onDevice }
final class AppSettings {
    var provider = SpeechProvider(id: "cloud")
    var languages = LanguagePair(first: .english, second: Language("fr"))
    var chineseScript = ChineseScript.simplified
    var translationModel = "test"
    var speaksTranslations = true
    var speechVoice = SpeechVoice.original
    var hasSpeechCredential = true
    func credential(_ credential: ProviderCredential) -> String { "test" }
}
protocol TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error>
}
enum TranslationError: LocalizedError {
    case missingPack
    var isPermanent: Bool { true }
    var errorDescription: String? { "Download languages first" }
}
enum Calls {
    static var local: [(String, Language, Language)] = []
    static var cloud = 0
    static var holdCloud = false
    static var missingPack = false
    static var pending: [AsyncThrowingStream<String, Error>.Continuation] = []
    static var cloudCancellations = 0
    static var localSpeakers = 0
    static var cloudSpeakers = 0
    static func reset() {
        local = []; cloud = 0; holdCloud = false; missingPack = false
        pending = []; cloudCancellations = 0; localSpeakers = 0; cloudSpeakers = 0
    }
}
struct AppleTranslator: TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error> {
        Calls.local.append((text, source, target))
        return AsyncThrowingStream { continuation in
            if Calls.missingPack { continuation.finish(throwing: TranslationError.missingPack) }
            else { continuation.yield("local:" + text); continuation.finish() }
        }
    }
}
struct CloudTranslator: TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error> {
        Calls.cloud += 1
        return AsyncThrowingStream { continuation in
            if Calls.holdCloud {
                Calls.pending.append(continuation)
                continuation.onTermination = { _ in Task { @MainActor in Calls.cloudCancellations += 1 } }
            } else { continuation.yield("cloud:" + text); continuation.finish() }
        }
    }
}
enum BrokerTranslator { static let shared: CloudTranslator? = CloudTranslator() }
struct MistralTranslator: TranslationService {
    let apiKey: String
    let model: String
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error> {
        CloudTranslator().translate(text, from: source, to: target, context: context, script: script)
    }
}
struct FallbackTranslator: TranslationService {
    let primary: any TranslationService
    let fallback: any TranslationService
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error> {
        primary.translate(text, from: source, to: target, context: context, script: script)
    }
}
final class SpeechPlayer { enum Output { case automatic, headphones, speaker } }
final class SonioxSpeaker {
    enum Credential { case test }
    let player = SpeechPlayer()
    var onError: (String) -> Void = { _ in }
    var stops = 0
    init(credential: Credential) { Calls.cloudSpeakers += 1 }
    static func credential(_ settings: AppSettings) -> Credential? { settings.hasSpeechCredential ? .test : nil }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output) {}
    func stop() { stops += 1 }
}
final class OfflineSpeaker {
    let player = SpeechPlayer()
    var onError: (String) -> Void = { _ in }
    var stops = 0
    init(script: ChineseScript) { Calls.localSpeakers += 1 }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output) {}
    func stop() { stops += 1 }
}
enum NWInterface { enum InterfaceType { case wifi, cellular } }
final class FakeEngine {
    var networkAvailable = true
    func networkPathChanged() {}
}

// INSERT_ACTUAL_LANGUAGE
// INSERT_ACTUAL_UTTERANCE
// INSERT_ACTUAL_SPEAKER_PROTOCOL

final class ConversationStore {
    let settings = AppSettings()
    var languages: LanguagePair { settings.languages }
    var utterances: [Utterance] = []
    var isOnline = true
    var isUsingOnDevice = false
    var demo: String?
    var translator: (any TranslationService)?
    var translations: [UUID: Task<Void, Never>] = [:]
    var speaker: (any TranslationSpeaker)?
    var speakerUsesOnDevice = false
    var speakingSince: Date? = .distantPast
    var spoken: [UUID: Int] = [:]
    var speechFlushes: [UUID: Task<Void, Never>] = [:]
    var interface: NWInterface.InterfaceType?
    var engine: FakeEngine?
    var alert: String?
    var speechCompletions = 0
    func speak(_ utterance: Utterance, stable: String, complete: Bool) { speechCompletions += 1 }
    func setSpeaksTranslations(_ on: Bool) { settings.speaksTranslations = on }
    func refreshStatus() {}
    func chooseSpeaker() -> (any TranslationSpeaker)? { activeSpeaker() }
    func changeNetwork(_ online: Bool) { setPath(online: online, interface: .wifi) }
    func translateSpeech(_ text: String) -> Utterance {
        let utterance = Utterance(source: text, language: .english, languages: languages)
        utterance.isFinal = true
        utterances.append(utterance)
        translate(utterance)
        return utterance
    }
    // INSERT_ACTUAL_STORE
}

@main struct OfflineStoreRegression {
    static var failures = 0
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: " + message) }
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        check(false, "translation completed without waiting for network")
    }
    static func drain() async { for _ in 0..<200 { await Task.yield() } }
    static func main() async {
        Calls.reset()
        let explicit = ConversationStore()
        explicit.settings.provider = .onDevice
        check(explicit.translatesTypedTextOnDevice, "typed input offers local model preparation before listening")
        explicit.submitTyped("Hello, how are you?", language: .english)
        await until { explicit.utterances.first?.translationState == .current }
        check(Calls.local.count == 1 && Calls.cloud == 0,
              "explicit on-device typed translation is local before microphone startup")
        check(explicit.translator == nil && explicit.speechCompletions == 1,
              "typed offline translation needs no listening engine")
        check(explicit.chooseSpeaker() is SonioxSpeaker && Calls.localSpeakers == 0,
              "on-device recognition retains the original voice while connected")

        Calls.reset()
        let disconnected = ConversationStore()
        disconnected.changeNetwork(false)
        check(disconnected.translatesTypedTextOnDevice, "disconnected typed input selects local model preparation")
        disconnected.submitTyped("Hello, how are you?", language: .english)
        disconnected.submitTyped("Bonjour, comment allez-vous?", language: Language("fr"))
        await until { disconnected.utterances.count == 2 && disconnected.utterances.allSatisfy { $0.translationState == .current } }
        check(Calls.local.count == 2 && Calls.cloud == 0,
              "offline typed input translates both directions without a cloud request")
        check(Set(Calls.local.map { $0.1.rawValue + ">" + $0.2.rawValue }) == ["en>fr", "fr>en"],
              "both source/target directions reach local translation")
        check(disconnected.chooseSpeaker() == nil && Calls.cloudSpeakers == 0 && Calls.localSpeakers == 0,
              "offline original voice neither starts cloud speech nor silently changes voices")
        disconnected.settings.speechVoice = .onDevice
        check(disconnected.chooseSpeaker() is OfflineSpeaker && Calls.cloudSpeakers == 0,
              "explicit device voice works offline without starting cloud speech")

        Calls.reset()
        let stopgap = ConversationStore()
        stopgap.isUsingOnDevice = true
        stopgap.translator = CloudTranslator()
        let spoken = stopgap.translateSpeech("A spoken local sentence.")
        await until { spoken.translationState == .current }
        check(Calls.local.count == 1 && Calls.cloud == 0,
              "local stopgap overrides a captured cloud translator")
        check(stopgap.chooseSpeaker() is SonioxSpeaker && Calls.localSpeakers == 0,
              "local recognition stopgap preserves the selected original voice while online")

        Calls.reset()
        let connected = ConversationStore()
        connected.submitTyped("An online sentence.", language: .english)
        await until { connected.utterances.first?.translationState == .current }
        check(Calls.cloud == 1 && Calls.local.isEmpty, "connected cloud mode retains cloud typed translation")
        let oldSpeaker = connected.chooseSpeaker() as? SonioxSpeaker
        check(oldSpeaker != nil, "connected cloud mode keeps cloud speech when available")
        connected.settings.provider = .onDevice
        check((connected.chooseSpeaker() as? SonioxSpeaker) === oldSpeaker && oldSpeaker?.stops == 0,
              "recognition provider change does not silently replace the original voice")
        let cutoff = Date.now
        let flush = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        connected.speechFlushes[UUID()] = flush
        connected.spoken[UUID()] = 12
        connected.settings.speechVoice = .onDevice
        connected.speechRoutingDidChange()
        check(oldSpeaker?.stops == 1 && connected.speaker == nil,
              "explicit voice change immediately stops the older producer")
        check(flush.isCancelled && connected.speechFlushes.isEmpty && connected.spoken.isEmpty,
              "voice change cancels old deferred speech and sent-text state")
        check(connected.speakingSince.map { $0 >= cutoff } == true,
              "voice change advances the old-turn speech cutoff")
        let selectedLocal = connected.chooseSpeaker() as? OfflineSpeaker
        check(selectedLocal != nil, "explicit device voice replaces original speech")
        connected.settings.speechVoice = .original
        connected.speechRoutingDidChange()
        check(selectedLocal?.stops == 1 && connected.chooseSpeaker() is SonioxSpeaker,
              "returning to the original voice stops the local producer")

        Calls.reset()
        let missingVoiceKey = ConversationStore()
        missingVoiceKey.settings.hasSpeechCredential = false
        check(!missingVoiceKey.canSpeakTranslations && missingVoiceKey.chooseSpeaker() == nil
                && Calls.localSpeakers == 0 && Calls.cloudSpeakers == 0,
              "missing original voice credentials do not silently enable a different voice")
        missingVoiceKey.settings.speechVoice = .onDevice
        check(missingVoiceKey.canSpeakTranslations && missingVoiceKey.chooseSpeaker() is OfflineSpeaker,
              "explicit local speech works without a cloud speech credential")

        Calls.reset()
        Calls.holdCloud = true
        let interrupted = ConversationStore()
        let cloudSpeech = interrupted.chooseSpeaker() as? SonioxSpeaker
        interrupted.submitTyped("Keep this sentence.", language: .english)
        await until { Calls.pending.count == 1 }
        interrupted.changeNetwork(false)
        await until { interrupted.utterances.first?.translationState == .current }
        check(Calls.local.count == 1 && Calls.cloud == 1,
              "network loss restarts an in-flight cloud request locally immediately")
        check(cloudSpeech?.stops == 1 && interrupted.chooseSpeaker() == nil && Calls.localSpeakers == 0,
              "network loss cancels original speech without substituting a device voice")
        Calls.pending[0].yield("late cloud reply")
        Calls.pending[0].finish()
        await drain()
        check(interrupted.utterances.first?.translation == "local:Keep this sentence.",
              "cancelled late cloud result cannot overwrite local translation")
        check(Calls.cloudCancellations == 1, "cloud translation stream receives cancellation")

        Calls.reset()
        Calls.missingPack = true
        let missing = ConversationStore()
        missing.settings.provider = .onDevice
        missing.submitTyped("Missing models.", language: .english)
        await until { if case .failed = missing.utterances.first?.translationState { return true }; return false }
        check(Calls.local.count == 1 && Calls.cloud == 0,
              "missing local models report failure without sending the text to cloud")
        print("Offline store regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
