// Settings-change scenarios use actual AppSettings, SonioxSpeaker, and the
// production speech/routing-change methods inserted by the Python runner.
enum AudioSessionUsers {
    static func setDirectionalSpeechEnabled(_ value: Bool) {}
}

final class Utterance {
    let id = UUID()
    let target: Language
    let languages: LanguagePair
    let createdAt: Date
    var isFinal = true
    init(target: Language, languages: LanguagePair, createdAt: Date = .now) {
        self.target = target
        self.languages = languages
        self.createdAt = createdAt
    }
}

final class ConversationStore {
    let settings: AppSettings
    let languages: LanguagePair
    var speaker: SonioxSpeaker?
    var speakingSince: Date? = .distantPast
    var spoken: [UUID: Int] = [:]
    var speechFlushes: [UUID: Task<Void, Never>] = [:]
    var alert: String?
    init(settings: AppSettings) { self.settings = settings; self.languages = settings.languages }
    func testSpeaker() -> SonioxSpeaker { activeSpeaker()! }
    func accept(_ turn: Utterance, text: String, complete: Bool) {
        speak(turn, stable: text, complete: complete)
    }
    // INSERT_ACTUAL_SPEECH_METHODS
}

@main struct DirectionalSpeechAdversarialSettings {
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS: \(message)") }
        else { failures += 1; print("FAIL: \(message)") }
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        check(false, "controlled suspension arrived")
    }
    static func drainActor() async { for _ in 0..<100 { await Task.yield() } }

    static func main() async throws {
        TestDefaults.standard.values = [:]
        let settings = AppSettings()
        settings.setCredential("test-only", for: .soniox)
        settings.speaksTranslations = true
        settings.speechListenerLanguage = .english
        let store = ConversationStore(settings: settings)
        let previous = Utterance(target: .english, languages: settings.languages)
        let oldSpeaker = store.testSpeaker()
        oldSpeaker.player.suspendPreparation = true
        store.accept(previous, text: "Earlier private sentence.", complete: true)
        await until { oldSpeaker.player.pending.count == 1 }

        let unfinished = Utterance(target: .chinese, languages: settings.languages)
        store.accept(unfinished, text: "unpunctuated tail", complete: false)
        check(!store.speechFlushes.isEmpty, "old unpunctuated turn has a deferred flush")
        settings.speechListenerLanguage = .chinese
        store.speechRoutingDidChange()
        check(oldSpeaker.player.stopCount == 1, "listener change immediately stops the old speech producer")
        check(store.speaker == nil && store.speechFlushes.isEmpty && store.spoken.isEmpty,
              "listener change discards producer, deferred flushes, and sent-text state")
        check(store.speakingSince.map { $0 > previous.createdAt && $0 > unfinished.createdAt } == true,
              "listener change advances the eligibility cutoff past old turns")

        // An old prepare callback returning after the hook cannot synthesize
        // old content for the newly selected wearer or consume fresh work.
        oldSpeaker.player.suspendPreparation = false
        oldSpeaker.player.pending.removeFirst().resume(returning: true)
        await drainActor()
        check(URLSession.shared.sent.isEmpty, "cancelled old line never reaches synthesis after listener change")
        store.accept(previous, text: "Earlier private sentence. A late update.", complete: true)
        store.accept(unfinished, text: "old tail now finished.", complete: true)
        await drainActor()
        check(store.speaker == nil && URLSession.shared.sent.isEmpty,
              "late updates to old turns cannot restart speech under the new listener")

        let incoming = Utterance(target: .chinese, languages: settings.languages)
        store.accept(incoming, text: "New private sentence.", complete: true)
        let newSpeaker = store.speaker!
        await until { URLSession.shared.sent.count == 2 }
        check(newSpeaker.player.preparations == [.headphones], "new incoming turn follows the newly selected listener")
        let outgoing = Utterance(target: .english, languages: settings.languages)
        store.accept(outgoing, text: "New public sentence.", complete: true)
        await until { URLSession.shared.sent.count == 4 }
        check(newSpeaker.player.preparations == [.headphones, .speaker], "new outgoing turn follows the newly selected listener")

        let oldPair = settings.languages
        settings.languages = LanguagePair(first: .english, second: Language("fr"))
        store.speechRoutingDidChange()
        check(newSpeaker.player.stopCount == 1 && store.speaker == nil, "pair change immediately stops current speech")
        store.accept(Utterance(target: .chinese, languages: oldPair), text: "Obsolete pair.", complete: true)
        await drainActor()
        check(store.speaker == nil && URLSession.shared.sent.count == 4,
              "old pair stays ineligible even when its completion arrives after the cutoff")

        settings.speaksTranslations = false
        store.speechRoutingDidChange()
        check(store.speakingSince == nil, "routing change while speech is disabled leaves no eligible turns")
        print("Adversarial settings result: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
