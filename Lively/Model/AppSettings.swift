import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var apiKey: String {
        didSet { Keychain.write(apiKey.isEmpty ? nil : apiKey, account: "mistral-api-key") }
    }

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

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        apiKey = Keychain.read(account: "mistral-api-key") ?? ""
        latency = Latency(rawValue: defaults.integer(forKey: "latency")) ?? .fastest
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .simplified
        translationModel = defaults.string(forKey: "translationModel") ?? Self.defaultTranslationModel
    }
}
