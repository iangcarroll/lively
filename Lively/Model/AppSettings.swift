import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Online discovery keeps the headphone wearer's language fixed and learns
    /// the other language from speech. The saved pair is for manual/offline use.
    var conversationMode: ConversationMode {
        didSet {
            defaults.set(conversationMode.rawValue, forKey: "conversationMode")
            publishWidgetLanguages()
        }
    }

    var usesAutomaticLanguageDetection: Bool {
        #if DEBUG
        // The demo is a scripted conversation in the saved pair.
        if defaults.bool(forKey: "LivelyDemo") { return false }
        #endif
        return conversationMode == .automatic && providerID == SpeechProvider.soniox.id
    }

    /// `SpeechProvider.id` of the chosen engine.
    var providerID: String {
        didSet {
            defaults.set(providerID, forKey: "speechProvider")
            if !provider.supports(languages) { languages = .default }
            publishWidgetLanguages()
        }
    }

    var provider: SpeechProvider { SpeechProvider.with(id: providerID) }

    /// API keys by `ProviderCredential.id`, mirrored to the Keychain.
    private var credentials: [String: String] = [:]

    var latency: Latency {
        didSet { defaults.set(latency.rawValue, forKey: "latency") }
    }

    /// The conversation's two languages. Always ones the provider supports.
    var languages: LanguagePair {
        didSet {
            defaults.set(languages.first.rawValue, forKey: "firstLanguage")
            defaults.set(languages.second.rawValue, forKey: "secondLanguage")
            publishWidgetLanguages()
        }
    }

    /// Sets one side of the pair. Choosing the other side's language swaps them.
    func setLanguage(_ language: Language, for side: WritableKeyPath<LanguagePair, Language>) {
        var pair = languages
        if pair.other(than: pair[keyPath: side]) == language {
            pair = LanguagePair(first: pair.second, second: pair.first)
        } else {
            pair[keyPath: side] = language
        }
        languages = pair
    }

    /// Optional: the pair follows the country the device is in. See `LocationLanguages`.
    var usesLocationLanguages: Bool {
        didSet { defaults.set(usesLocationLanguages, forKey: "usesLocationLanguages") }
    }

    /// The country the pair was last set for, so a choice made there by hand sticks.
    var locationLanguageRegion: String? {
        didSet { defaults.set(locationLanguageRegion, forKey: "locationLanguageRegion") }
    }

    /// How far away the mic listens; quieter sound is sent as silence.
    var pickupRange: PickupRange {
        didSet { defaults.set(pickupRange.rawValue, forKey: "pickupRange") }
    }

    var chineseScript: ChineseScript {
        didSet { defaults.set(chineseScript.rawValue, forKey: "chineseScript") }
    }

    var translationModel: String {
        didSet { defaults.set(translationModel, forKey: "translationModel") }
    }

    /// Speech-to-speech mode. On supported iPhones, incoming translations
    /// go to a headset and outgoing translations go to the built-in speaker.
    var speaksTranslations: Bool {
        didSet { defaults.set(speaksTranslations, forKey: "speaksTranslations") }
    }

    var speechSource: SpeechSource {
        didSet { defaults.set(speechSource.rawValue, forKey: "speechSource") }
    }

    private var speechListenerLanguageCode: String {
        didSet {
            defaults.set(speechListenerLanguageCode, forKey: "speechListenerLanguage")
            publishWidgetLanguages()
        }
    }

    /// The headset wearer's language, independent of the face-to-face layout.
    var speechListenerLanguage: Language {
        get {
            let language = Language(speechListenerLanguageCode)
            if usesAutomaticLanguageDetection {
                return Language.soniox.contains(language) ? language : .english
            }
            return languages.contains(language) ? language : languages.first
        }
        set {
            guard usesAutomaticLanguageDetection
                ? Language.soniox.contains(newValue) : languages.contains(newValue) else { return }
            speechListenerLanguageCode = newValue.rawValue
        }
    }

    private var offlineSpokenLanguageCode: String {
        didSet { defaults.set(offlineSpokenLanguageCode, forKey: "offlineSpokenLanguage") }
    }

    /// Offline recognition uses an explicit language instead of guessing from
    /// competing recognizers. Changing the pair keeps this selection valid.
    var offlineSpokenLanguage: Language {
        get {
            let language = Language(offlineSpokenLanguageCode)
            return languages.contains(language) ? language : languages.first
        }
        set {
            guard languages.contains(newValue) else { return }
            offlineSpokenLanguageCode = newValue.rawValue
        }
    }

    static let defaultTranslationModel = "mistral-small-latest"
    static let transcriptionModel = "voxtral-mini-transcribe-realtime-3"

    func credential(_ credential: ProviderCredential) -> String {
        credentials[credential.id] ?? ""
    }

    func setCredential(_ value: String, for credential: ProviderCredential) {
        guard credentials[credential.id] != value else { return }
        credentials[credential.id] = value
        Keychain.write(value.isEmpty ? nil : value, account: credential.id)
    }

    /// The chosen provider has every key it needs.
    var hasCredentials: Bool {
        provider.credentials.allSatisfy { $0.isOptional || !credential($0).trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private init() {
        let mode = ConversationMode.initial(
            saved: defaults.string(forKey: "conversationMode"), onboardingDone: defaults.bool(forKey: "onboardingDone"))
        // Saved at once, so finishing the welcome tour doesn't change it.
        defaults.set(mode.rawValue, forKey: "conversationMode")
        conversationMode = mode
        let providerID = defaults.string(forKey: "speechProvider") ?? SpeechProvider.fallback.id
        self.providerID = providerID
        let stored = LanguagePair(
            first: Language(defaults.string(forKey: "firstLanguage") ?? LanguagePair.default.first.rawValue),
            second: Language(defaults.string(forKey: "secondLanguage") ?? LanguagePair.default.second.rawValue)
        )
        languages = SpeechProvider.with(id: providerID).supports(stored) && stored.first != stored.second ? stored : .default
        usesLocationLanguages = defaults.bool(forKey: "usesLocationLanguages")
        locationLanguageRegion = defaults.string(forKey: "locationLanguageRegion")
        latency = Latency(rawValue: defaults.integer(forKey: "latency")) ?? .fastest
        pickupRange = PickupRange(rawValue: defaults.string(forKey: "pickupRange") ?? "") ?? .default
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .simplified
        translationModel = defaults.string(forKey: "translationModel") ?? Self.defaultTranslationModel
        speaksTranslations = defaults.bool(forKey: "speaksTranslations")
        speechSource = SpeechSource(rawValue: defaults.string(forKey: "speechSource") ?? "") ?? .original
        // The device voice option was removed. Don't retain an old selection.
        defaults.set(nil, forKey: "speechVoice")
        speechListenerLanguageCode = defaults.string(forKey: "speechListenerLanguage") ?? stored.first.rawValue
        offlineSpokenLanguageCode = defaults.string(forKey: "offlineSpokenLanguage") ?? stored.first.rawValue
        for credential in SpeechProvider.allCredentials {
            credentials[credential.id] = Keychain.read(account: credential.id) ?? ""
        }
        // didSet doesn't run here; the widgets may not have this pair yet.
        publishWidgetLanguages()
    }

    private func publishWidgetLanguages() {
        #if os(iOS)
        if usesAutomaticLanguageDetection {
            WidgetLanguages.publishAutomatic(listener: speechListenerLanguage)
        } else {
            WidgetLanguages.publish(languages)
        }
        #endif
    }
}

enum ConversationMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, pair
    var id: String { rawValue }

    /// The mode at launch. Automatic is for new installs; someone who set
    /// Lively up before it existed keeps their pair, which also works offline.
    static func initial(saved: String?, onboardingDone: Bool) -> ConversationMode {
        saved.flatMap(ConversationMode.init) ?? (onboardingDone ? .pair : .automatic)
    }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .pair: "Choose a pair"
        }
    }
}

enum SpeechSource: String, CaseIterable, Identifiable, Sendable {
    case original, downloaded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Original voice · online"
        case .downloaded: "Downloaded voices · offline"
        }
    }
}
