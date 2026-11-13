import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// `SpeechProvider.id` of the chosen engine.
    var providerID: String {
        didSet {
            defaults.set(providerID, forKey: "speechProvider")
            if !provider.supports(languages) { languages = .default }
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
            #if os(iOS)
            WidgetLanguages.publish(languages)
            #endif
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

    private var speechListenerLanguageCode: String {
        didSet { defaults.set(speechListenerLanguageCode, forKey: "speechListenerLanguage") }
    }

    /// The headset wearer's language, independent of the face-to-face layout.
    var speechListenerLanguage: Language {
        get {
            let language = Language(speechListenerLanguageCode)
            return languages.contains(language) ? language : languages.first
        }
        set {
            guard languages.contains(newValue) else { return }
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
        let providerID = defaults.string(forKey: "speechProvider") ?? SpeechProvider.fallback.id
        self.providerID = providerID
        let stored = LanguagePair(
            first: Language(defaults.string(forKey: "firstLanguage") ?? LanguagePair.default.first.rawValue),
            second: Language(defaults.string(forKey: "secondLanguage") ?? LanguagePair.default.second.rawValue)
        )
        languages = SpeechProvider.with(id: providerID).supports(stored) && stored.first != stored.second ? stored : .default
        latency = Latency(rawValue: defaults.integer(forKey: "latency")) ?? .fastest
        pickupRange = PickupRange(rawValue: defaults.string(forKey: "pickupRange") ?? "") ?? .default
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .simplified
        translationModel = defaults.string(forKey: "translationModel") ?? Self.defaultTranslationModel
        speaksTranslations = defaults.bool(forKey: "speaksTranslations")
        // The device voice option was removed. Don't retain an old selection.
        defaults.set(nil, forKey: "speechVoice")
        speechListenerLanguageCode = defaults.string(forKey: "speechListenerLanguage") ?? stored.first.rawValue
        offlineSpokenLanguageCode = defaults.string(forKey: "offlineSpokenLanguage") ?? stored.first.rawValue
        for credential in SpeechProvider.allCredentials {
            credentials[credential.id] = Keychain.read(account: credential.id) ?? ""
        }
        #if os(iOS)
        // didSet doesn't run here; the widgets may not have this pair yet.
        WidgetLanguages.publish(languages)
        #endif
    }
}
