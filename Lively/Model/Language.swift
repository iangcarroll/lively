import Foundation

/// The two sides of a Lively conversation.
enum Language: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    var other: Language { self == .english ? .chinese : .english }

    /// Short tag shown next to text in this language.
    var tag: String { self == .english ? "EN" : "中文" }

    /// Name of the language written in that language.
    var nativeName: String { self == .english ? "English" : "中文" }

    var locale: Locale { Locale(identifier: self == .english ? "en" : "zh-Hans") }

    /// Guesses the language of a transcript from its script. Voxtral returns
    /// Han characters for Mandarin and Latin letters for English, so counting
    /// scripts is instant and reliable enough. Mixed speech ("我们去 Starbucks")
    /// counts as Chinese because the Han characters carry most of the meaning.
    static func detect(_ text: String) -> Language? {
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
        // A Han character is roughly a syllable; an English word is ~4-5 letters.
        return Double(han) >= Double(latin) / 4.0 ? .chinese : .english
    }
}

enum ChineseScript: String, CaseIterable, Identifiable, Sendable {
    case simplified, traditional

    var id: String { rawValue }
    var label: String { self == .simplified ? "简体" : "繁體" }
    var promptName: String { self == .simplified ? "Simplified Chinese" : "Traditional Chinese" }
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
