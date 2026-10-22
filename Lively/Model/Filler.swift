import Foundation

/// Strips hesitation sounds ("um", "uh", "呃", "嗯") from transcripts so they
/// don't get translated or take up space. A turn that is only filler ends up
/// empty and is dropped.
enum Filler {
    /// English fillers as whole words, with the commas or ellipsis around them.
    private static let english = try! NSRegularExpression(
        pattern: #"(?:,\s*)?(?<![\p{L}'])(?:u+m+|u+h+|e+r+m*|h+m+|m{2,})(?![\p{L}'])[,.…!?]*\s*"#,
        options: [.caseInsensitive]
    )

    /// Chinese fillers standing on their own: at the start or after
    /// punctuation, and followed by punctuation or the end. "好啊" keeps its 啊.
    private static let chinese = try! NSRegularExpression(
        pattern: #"(^|[，。！？、；,.!?;\s])[嗯呃额唔]+(?:[，、,…\s]+|(?=[。！？.!?]|$))"#
    )

    /// Punctuation left dangling at the start once a leading filler is gone.
    private static let leadingPunctuation = try! NSRegularExpression(pattern: #"^[\s，。、,.…!?！？]+"#)

    /// Doubled spaces and spaces before punctuation, left where a filler was.
    private static let looseSpace = try! NSRegularExpression(pattern: #"(?<= ) +| +(?=[,.!?])"#)

    static func strip(_ text: String) -> String {
        var result = text
        result = replace(english, in: result, with: " ")
        result = replace(chinese, in: result, with: "$1")
        result = replace(leadingPunctuation, in: result, with: "")
        result = replace(looseSpace, in: result, with: "")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence-final "嗯。" can leave "好的，。" behind.
        result = result.replacingOccurrences(of: "，。", with: "。")
        result = result.replacingOccurrences(of: ", .", with: ".")
        // "Um, so we..." reads better as "So we...".
        if text.first?.isUppercase == true, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
