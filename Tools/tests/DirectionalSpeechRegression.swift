// Deterministic fixtures for directional_speech_regression.py. Production
// model/settings/speaker code is inserted verbatim at the markers below.
import Foundation

final class TestDefaults {
    static let standard = TestDefaults()
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
struct ProviderCredential {
    let id: String
    var isOptional = true
    static let soniox = ProviderCredential(id: "soniox")
}
struct SpeechProvider {
    let id: String
    static let fallback = SpeechProvider(id: "test")
    static let allCredentials: [ProviderCredential] = [.soniox]
    var credentials: [ProviderCredential] { Self.allCredentials }
    static func with(id: String) -> SpeechProvider { Self(id: id) }
    func supports(_ pair: LanguagePair) -> Bool { true }
}
enum PickupRange: String { case nearby; static let `default` = Self.nearby }
enum Keychain {
    static func read(account: String) -> String? { nil }
    static func write(_ value: String?, account: String) {}
}
enum SocketSetupError: Error { case fail(String) }
final class SonioxKeyProvider {
    struct Key { let value: String; let websocketURL: URL }
    static var shared: SonioxKeyProvider?
    var pending: [CheckedContinuation<Key, Error>] = []
    func takeSpeechKey() async throws -> Key {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

final class SpeechPlayer {
    enum Output: Equatable { case automatic, headphones, speaker }
    static let sampleRate: Double = 24_000
    static var supportsDirectionalOutput = true
    var preparations: [Output] = []
    var prepareResult = true
    var suspendPreparation = false
    var pending: [CheckedContinuation<Bool, Error>] = []
    var stopCount = 0
    var played: [Data] = []
    func prepare(output: Output) async throws -> Bool {
        preparations.append(output)
        if suspendPreparation {
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        return prepareResult
    }
    func play(_ data: Data) { played.append(data) }
    func stop() { stopCount += 1 }
}

// Shadow URLSession so the actual SonioxSpeaker cannot make network requests.
final class URLSession {
    static let shared = URLSession()
    var sockets: [URLSessionWebSocketTask] = []
    func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask {
        let socket = URLSessionWebSocketTask()
        sockets.append(socket)
        return socket
    }
    var sent: [[String: Any]] { sockets.flatMap(\.sent) }
    func reset() { sockets.removeAll() }
}
final class URLSessionWebSocketTask {
    enum State { case running, completed }
    enum CloseCode { case normalClosure }
    enum Message {
        case object([String: Any])
        static func json(_ object: [String: Any]) -> Message { .object(object) }
        var jsonObject: [String: Any]? {
            if case .object(let object) = self { return object }
            return nil
        }
    }
    var state = State.running
    var sent: [[String: Any]] = []
    private var stream = ""
    func resume() {}
    func cancel(with: CloseCode, reason: Data?) { state = .completed }
    func send(_ message: Message) async throws {
        let object = message.jsonObject!
        sent.append(object)
        stream = object["stream_id"] as? String ?? stream
    }
    func receive() async throws -> Message { .object(["stream_id": stream, "terminated": true]) }
}

// INSERT_ACTUAL_LANGUAGE
// INSERT_ACTUAL_SETTINGS
// INSERT_ACTUAL_SPEAKER

final class Utterance {
    let id = UUID()
    let target: Language
    let languages: LanguagePair
    let createdAt = Date.now
    var isFinal = true
    init(target: Language, languages: LanguagePair) { self.target = target; self.languages = languages }
}
final class ConversationStore {
    let settings: AppSettings
    let languages: LanguagePair
    var speakingSince: Date? = .distantPast
    var spoken: [UUID: Int] = [:]
    var speechFlushes: [UUID: Task<Void, Never>] = [:]
    let speaker = SonioxSpeaker(credential: .apiKey("test-only"))
    init(settings: AppSettings) { self.settings = settings; languages = settings.languages }
    func activeSpeaker() -> SonioxSpeaker? { speaker }
    func testSpeak(target: Language, text: String = "Sentence.", turnLanguages: LanguagePair? = nil) {
        speak(Utterance(target: target, languages: turnLanguages ?? languages), stable: text, complete: true)
    }
    // INSERT_ACTUAL_SPEECH_METHODS
}

@main struct DirectionalSpeechRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        check(false, "timed out waiting for controlled suspension")
    }
    static func drain() async { for _ in 0..<100 { await Task.yield() } }
    static func main() async throws {
        // Persistence is tested against the full production AppSettings source.
        TestDefaults.standard.values = [:]
        let settings = AppSettings()
        check(settings.speechListenerLanguage == .english, "default listener is not first language")
        settings.speechListenerLanguage = .chinese
        check(TestDefaults.standard.string(forKey: "speechListenerLanguage") == "zh", "listener not persisted")
        let reloaded = AppSettings()
        check(reloaded.speechListenerLanguage == .chinese, "listener did not survive reload")
        reloaded.languages = LanguagePair(first: .english, second: Language("fr"))
        check(reloaded.speechListenerLanguage == .english, "removed listener did not fall back to first language")
        reloaded.speechListenerLanguage = .chinese
        check(reloaded.speechListenerLanguage == .english, "invalid listener escaped current pair")
        reloaded.speechListenerLanguage = Language("fr")
        check(AppSettings().speechListenerLanguage == Language("fr"), "new-pair listener did not persist")

        // Both target directions are routed for either possible listener choice.
        settings.speaksTranslations = true
        settings.speechListenerLanguage = .english
        SpeechPlayer.supportsDirectionalOutput = true
        let store = ConversationStore(settings: settings)
        store.testSpeak(target: .english)
        store.testSpeak(target: .chinese)
        await until { store.speaker.player.preparations.count == 2 }
        check(store.speaker.player.preparations == [.headphones, .speaker], "English listener received wrong destinations")
        settings.speechListenerLanguage = .chinese
        store.testSpeak(target: .english)
        store.testSpeak(target: .chinese)
        await until { store.speaker.player.preparations.count == 4 }
        check(Array(store.speaker.player.preparations.suffix(2)) == [.speaker, .headphones], "Chinese listener received wrong destinations")
        await drain()
        store.speaker.stop()

        // Translations from the prior pair may finish while Settings is open.
        // They must not become public merely because the listener fell back.
        let priorPair = settings.languages
        let changed = ConversationStore(settings: settings)
        settings.languages = LanguagePair(first: .english, second: Language("fr"))
        changed.testSpeak(target: .chinese, turnLanguages: priorPair)
        await drain()
        check(changed.speaker.player.preparations.isEmpty, "old pair translation reached playback")
        settings.languages = priorPair

        // Unsupported OS/macOS retains the second-language-only automatic route.
        SpeechPlayer.supportsDirectionalOutput = false
        let legacy = ConversationStore(settings: settings)
        legacy.testSpeak(target: .english)
        legacy.testSpeak(target: .chinese)
        await until { legacy.speaker.player.preparations.count == 1 }
        check(legacy.speaker.player.preparations == [.automatic], "legacy routing changed")
        await drain()
        legacy.speaker.stop()

        // Queue entries retain their destination while an earlier line drains.
        URLSession.shared.reset()
        let queued = SonioxSpeaker(credential: .apiKey("test-only"))
        queued.player.suspendPreparation = true
        queued.speak(" First. ", in: .english, output: .headphones)
        queued.speak("Second.", in: .chinese, output: .speaker)
        await until { queued.player.pending.count == 1 }
        queued.player.suspendPreparation = false
        queued.player.pending.removeFirst().resume(returning: true)
        await until { URLSession.shared.sent.count == 4 }
        check(queued.player.preparations == [.headphones, .speaker], "queued output was not captured per line")
        check(URLSession.shared.sent.compactMap { $0["text"] as? String } == ["First.", "Second."], "line order/text changed")
        queued.stop()

        // No destination means no socket or synthesis request, then queue proceeds.
        URLSession.shared.reset()
        let unavailable = SonioxSpeaker(credential: .apiKey("test-only"))
        unavailable.player.prepareResult = false
        unavailable.speak("Private.", in: .english, output: .headphones)
        await until { unavailable.player.preparations.count == 1 }
        await drain()
        check(URLSession.shared.sockets.isEmpty && URLSession.shared.sent.isEmpty,
              "missing destination sent a synthesis request")
        unavailable.player.prepareResult = true
        unavailable.speak("Public.", in: .chinese, output: .speaker)
        await until { URLSession.shared.sent.count == 2 }
        check(URLSession.shared.sent.last?["text"] as? String == "Public.", "skipped line blocked subsequent speech")
        unavailable.stop()

        // A cancelled drain may return late after a newer worker starts. It must
        // neither send the old line nor consume the new worker's queued lines.
        URLSession.shared.reset()
        let cancelled = SonioxSpeaker(credential: .apiKey("test-only"))
        cancelled.player.suspendPreparation = true
        cancelled.speak("Old.", in: .english, output: .headphones)
        cancelled.speak("Dropped.", in: .chinese, output: .speaker)
        await until { cancelled.player.pending.count == 1 }
        cancelled.stop()
        cancelled.player.suspendPreparation = false
        cancelled.speak("New.", in: .chinese, output: .speaker)
        await until { URLSession.shared.sent.count == 2 }
        cancelled.player.pending.removeFirst().resume(returning: true)
        await drain()
        check(URLSession.shared.sent.compactMap { $0["text"] as? String } == ["New."],
              "cancelled worker synthesized stale or cleared speech")
        cancelled.speak("Newest.", in: .english, output: .headphones)
        await until { URLSession.shared.sent.count == 4 }
        check(URLSession.shared.sent.compactMap { $0["text"] as? String } == ["New.", "Newest."],
              "stale worker prevented subsequent speech")
        cancelled.stop()

        // Broker denials can also arrive after cancellation. They must not
        // clear a new worker's queue, close its socket or report a fatal error.
        URLSession.shared.reset()
        let broker = SonioxKeyProvider()
        let staleDenial = SonioxSpeaker(credential: .broker(broker))
        var errors: [String] = []
        staleDenial.onError = { errors.append($0) }
        staleDenial.speak("Old broker request.", in: .english, output: .headphones)
        await until { broker.pending.count == 1 }
        staleDenial.stop()
        staleDenial.player.suspendPreparation = true
        staleDenial.speak("Current.", in: .chinese, output: .speaker)
        staleDenial.speak("Following.", in: .english, output: .headphones)
        await until { staleDenial.player.pending.count == 1 }
        broker.pending.removeFirst().resume(throwing: SocketSetupError.fail("expired old denial"))
        await drain()
        check(errors.isEmpty && URLSession.shared.sockets.isEmpty, "cancelled broker denial affected new worker")
        staleDenial.player.suspendPreparation = false
        staleDenial.player.pending.removeFirst().resume(returning: true)
        await until { broker.pending.count == 1 }
        broker.pending.removeFirst().resume(returning: .init(value: "test-only", websocketURL: URL(string: "wss://test.invalid/")!))
        await until { URLSession.shared.sent.count == 4 }
        check(URLSession.shared.sent.compactMap { $0["text"] as? String } == ["Current.", "Following."],
              "cancelled broker denial cleared a new queue")
        staleDenial.stop()

        print("PASS: listener persistence/fallback, both directional targets, old pair, legacy routing, per-line queue, unavailable output, cancelled drain/broker denial")
    }
}
