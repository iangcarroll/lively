import Foundation
import NaturalLanguage

/// A spoken language, by ISO 639-1 code.
struct Language: Hashable, Identifiable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ code: String) { rawValue = code }

    static let english = Language("en")
    static let chinese = Language("zh")

    var id: String { rawValue }

    /// Short tag shown next to text in this language.
    var tag: String { self == .chinese ? "中文" : rawValue.uppercased() }

    /// Name of the language in English, e.g. "Spanish".
    var englishName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    /// Name of the language written in that language, e.g. "Español".
    var nativeName: String {
        guard let name = locale.localizedString(forLanguageCode: rawValue) else { return englishName }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// "Spanish · Español", or just "English" when the names match.
    var pickerName: String {
        englishName == nativeName ? englishName : "\(englishName) · \(nativeName)"
    }

    var locale: Locale { Locale(identifier: self == .chinese ? "zh-Hans" : rawValue) }

    /// What `NLLanguageRecognizer` calls this language, where it differs from the code.
    fileprivate var recognizerLanguages: [NLLanguage] {
        switch rawValue {
        case "zh": [.simplifiedChinese, .traditionalChinese]
        case "no": [.norwegian]
        default: [NLLanguage(rawValue)]
        }
    }

    /// Guesses which of the pair a transcript is in, for engines that don't say.
    ///
    /// Chinese with a Latin-script language is told apart by counting
    /// scripts, which is instant and handles mixed speech ("我们去 Starbucks"
    /// counts as Chinese because the Han characters carry most of the
    /// meaning). Other pairs go to `NLLanguageRecognizer`, limited to the two.
    static func detect(_ text: String, in languages: LanguagePair) -> Language? {
        if languages.contains(.chinese), languages.other(than: .chinese).usesLatinScript {
            var han = 0
            var latin = 0
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                    han += 1
                case 0x41...0x5A, 0x61...0x7A:
                    latin += 1
                default:
                    break
                }
            }
            if han == 0 && latin == 0 { return nil }
            // A Han character is roughly a syllable; a Latin-script word is ~4-5 letters.
            return Double(han) >= Double(latin) / 4.0 ? .chinese : languages.other(than: .chinese)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.all.flatMap(\.recognizerLanguages)
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return languages.all.first { $0.recognizerLanguages.contains(dominant) }
    }

    var usesLatinScript: Bool { Self.latinScript.contains(rawValue) }

    private static let latinScript: Set<String> = [
        "af", "sq", "az", "eu", "bs", "ca", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de",
        "hu", "id", "it", "lv", "lt", "ms", "no", "pl", "pt", "ro", "sk", "sl", "es", "sw", "sv", "tl",
        "tr", "vi", "cy",
    ]

    /// Every language Soniox transcribes; it translates between any two.
    /// https://soniox.com/docs/stt/concepts/supported-languages
    static let soniox: [Language] = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en",
        "et", "fi", "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko",
        "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
        "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
    ].map { Language($0) }

    /// The 13 languages Voxtral transcribes.
    static let voxtral: [Language] = [
        "en", "zh", "hi", "es", "ar", "fr", "pt", "ru", "de", "ja", "ko", "it", "nl",
    ].map { Language($0) }

    /// Languages Apple's on-device speech recognizer can listen for. The
    /// offline engine checks the exact list for this device at runtime with
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)`.
    static let appleOnDevice: [Language] = [
        "en", "zh", "es", "fr", "de", "it", "ja", "ko", "pt", "ru", "ar", "hi", "nl", "tr", "pl",
        "th", "vi", "uk", "id", "sv", "da", "no", "fi", "ms", "cs", "hu", "ro", "sk", "hr", "ca",
        "el", "he",
    ].map { Language($0) }
}

/// The two languages of a conversation. Lively listens for both and
/// translates each into the other.
struct LanguagePair: Hashable, Sendable {
    /// Shown first: the leading side of the chat and the left column.
    var first: Language
    var second: Language

    static let `default` = LanguagePair(first: .english, second: .chinese)

    var all: [Language] { [first, second] }

    func contains(_ language: Language) -> Bool { language == first || language == second }

    func other(than language: Language) -> Language { language == first ? second : first }

    /// The pair's member with this code, or nil for a language outside the pair.
    func language(code: String?) -> Language? {
        all.first { $0.rawValue == code }
    }
}

enum ChineseScript: String, CaseIterable, Identifiable, Sendable {
    case simplified, traditional

    var id: String { rawValue }
    /// English first, for whoever is setting Lively up.
    var label: String { self == .simplified ? "Simplified 简体" : "Traditional 繁體" }
    var promptName: String { self == .simplified ? "Simplified Chinese" : "Traditional Chinese" }

    /// Rewrites Simplified Chinese in this script, for engines that only
    /// output Simplified. Other text passes through unchanged.
    func convert(_ text: String) -> String {
        guard self == .traditional else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }
}

/// Streaming delay for Voxtral Realtime. Lower is faster, higher is more accurate.
enum Latency: Int, CaseIterable, Identifiable, Sendable {
    case fastest = 240
    case balanced = 480
    case accurate = 960

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fastest: "Fastest"
        case .balanced: "Balanced"
        case .accurate: "Accurate"
        }
    }
    var milliseconds: Int { rawValue }
}
