import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// `SpeechProvider.id` of the chosen engine.
    var providerID: String {
        didSet { defaults.set(providerID, forKey: "speechProvider") }
    }

    var provider: SpeechProvider { SpeechProvider.with(id: providerID) }

    /// API keys by `ProviderCredential.id`, mirrored to the Keychain.
    private var credentials: [String: String] = [:]

    var latency: Latency {
        didSet { defaults.set(latency.rawValue, forKey: "latency") }
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
        provider.credentials.allSatisfy { !credential($0).trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private init() {
        providerID = defaults.string(forKey: "speechProvider") ?? SpeechProvider.fallback.id
        latency = Latency(rawValue: defaults.integer(forKey: "latency")) ?? .fastest
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .simplified
        translationModel = defaults.string(forKey: "translationModel") ?? Self.defaultTranslationModel
        for credential in SpeechProvider.allCredentials {
            credentials[credential.id] = Keychain.read(account: credential.id) ?? ""
        }
    }
}
