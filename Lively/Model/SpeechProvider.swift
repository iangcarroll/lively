import Foundation

/// A choice of speech engine in Settings, and how to build it.
///
/// To add a provider, write a `SpeechEngine`, describe it with a
/// `SpeechProvider` next to it, and list it in `SpeechProvider.all`. Settings,
/// credential storage and the conversation pipeline pick it up from here.
struct SpeechProvider: Identifiable {
    /// Stable, persisted in user defaults.
    let id: String
    let name: String
    let summary: String
    /// API keys this provider needs, in the order Settings shows them.
    let credentials: [ProviderCredential]
    /// App settings that affect this provider, so Settings shows only those.
    let options: Set<ProviderOption>
    /// Languages it can listen for, in any pair.
    let languages: [Language]
    let makePipeline: (AppSettings) -> SpeechPipeline

    func supports(_ pair: LanguagePair) -> Bool {
        pair.all.allSatisfy(languages.contains)
    }

    static let all: [SpeechProvider] = [.soniox, .voxtralMistral]
    /// Soniox won the 2026-10-20 benchmark (Tools/probe/RESULTS.md): every
    /// turn translated, no leaks, lowest cost.
    static let fallback = SpeechProvider.soniox

    static func with(id: String) -> SpeechProvider {
        all.first { $0.id == id } ?? fallback
    }

    /// Every credential any provider uses, without duplicates.
    static var allCredentials: [ProviderCredential] {
        var seen = Set<String>()
        return all.flatMap(\.credentials).filter { seen.insert($0.id).inserted }
    }
}

/// An API key stored in the Keychain. Providers that share a key (two
/// services from one vendor) share a credential.
struct ProviderCredential: Identifiable, Hashable {
    /// Keychain account name.
    let id: String
    let name: String
    let help: String
    /// Settings may leave it empty, because the app can get keys another way.
    var isOptional = false
}

enum ProviderOption: Hashable {
    /// `AppSettings.latency`.
    case speed
    /// `AppSettings.translationModel`.
    case translationModel
}

struct SpeechPipeline {
    var engine: SpeechEngine
    /// Nil when the engine translates by itself.
    var translator: TranslationService?
}
