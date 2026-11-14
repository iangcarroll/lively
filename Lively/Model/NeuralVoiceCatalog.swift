import Foundation

nonisolated struct NeuralVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let languageCode: String
    let localeIdentifier: String

    var embeddingPath: String { "voices/\(id).json" }
    var languageName: String { NeuralVoiceCatalog.language(with: languageCode)?.name ?? languageCode }
    var nativeLanguageName: String { NeuralVoiceCatalog.language(with: languageCode)?.nativeName ?? languageCode }
    var accent: String? {
        switch localeIdentifier {
        case "en-US": "American"
        case "en-GB": "British"
        case "pt-BR": "Brazilian"
        default: nil
        }
    }
}

nonisolated struct NeuralVoiceLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let nativeName: String
    let defaultVoiceID: String
    var voices: [NeuralVoice] { NeuralVoiceCatalog.voices.filter { $0.languageCode == id } }
}

/// Presets actually shipped by Kokoro v1.0. This catalog is independent of
/// the conversation pair and doesn't imply recognition/translation support.
nonisolated enum NeuralVoiceCatalog {
    static let repository = "aufklarer/Kokoro-82M-CoreML-INT8"
    static let revision = "4ef656f55554ceb242ed11febbdbbffd60dd5938"
    static let languages: [NeuralVoiceLanguage] = [
        .init(id: "en", name: "English", nativeName: "English", defaultVoiceID: "af_heart"),
        .init(id: "fr", name: "French", nativeName: "Français", defaultVoiceID: "ff_siwis"),
        .init(id: "hi", name: "Hindi", nativeName: "हिन्दी", defaultVoiceID: "hf_alpha"),
        .init(id: "it", name: "Italian", nativeName: "Italiano", defaultVoiceID: "if_sara"),
        .init(id: "ja", name: "Japanese", nativeName: "日本語", defaultVoiceID: "jf_alpha"),
        .init(id: "zh", name: "Mandarin Chinese", nativeName: "普通话", defaultVoiceID: "zf_xiaoxiao"),
        .init(id: "pt", name: "Portuguese", nativeName: "Português", defaultVoiceID: "pf_dora"),
        .init(id: "es", name: "Spanish", nativeName: "Español", defaultVoiceID: "ef_dora"),
    ]

    static let voices: [NeuralVoice] = {
        let groups: [(String, String, String, [String])] = [
            ("en", "en-US", "af", ["alloy", "aoede", "bella", "heart", "jessica", "kore", "nicole", "nova", "river", "sarah", "sky"]),
            ("en", "en-US", "am", ["adam", "echo", "eric", "fenrir", "liam", "michael", "onyx", "puck", "santa"]),
            ("en", "en-GB", "bf", ["alice", "emma", "isabella", "lily"]),
            ("en", "en-GB", "bm", ["daniel", "fable", "george", "lewis"]),
            ("es", "es-ES", "ef", ["dora"]),
            ("es", "es-ES", "em", ["alex", "santa"]),
            ("fr", "fr-FR", "ff", ["siwis"]),
            ("hi", "hi-IN", "hf", ["alpha", "beta"]),
            ("hi", "hi-IN", "hm", ["omega", "psi"]),
            ("it", "it-IT", "if", ["sara"]),
            ("it", "it-IT", "im", ["nicola"]),
            ("ja", "ja-JP", "jf", ["alpha", "gongitsune", "nezumi", "tebukuro"]),
            ("ja", "ja-JP", "jm", ["kumo"]),
            ("pt", "pt-BR", "pf", ["dora"]),
            ("pt", "pt-BR", "pm", ["alex", "santa"]),
            ("zh", "zh-CN", "zf", ["xiaobei", "xiaoni", "xiaoxiao", "xiaoyi"]),
            ("zh", "zh-CN", "zm", ["yunjian", "yunxi", "yunxia", "yunyang"]),
        ]
        return groups.flatMap { language, locale, prefix, names in
            names.map { name in
                NeuralVoice(id: "\(prefix)_\(name)", name: name.prefix(1).uppercased() + name.dropFirst(),
                            languageCode: language, localeIdentifier: locale)
            }
        }
    }()

    static func language(with code: String) -> NeuralVoiceLanguage? { languages.first { $0.id == code } }
    static func voice(with id: String) -> NeuralVoice? { voices.first { $0.id == id } }
}
