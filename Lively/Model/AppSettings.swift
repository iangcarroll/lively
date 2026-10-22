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

    var chineseScript: ChineseScript {
        didSet { defaults.set(chineseScript.rawValue, forKey: "chineseScript") }
    }

    var translationModel: String {
        didSet { defaults.set(translationModel, forKey: "translationModel") }
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
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .simplified
        translationModel = defaults.string(forKey: "translationModel") ?? Self.defaultTranslationModel
        for credential in SpeechProvider.allCredentials {
            credentials[credential.id] = Keychain.read(account: credential.id) ?? ""
        }
    }
}
