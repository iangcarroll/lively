import SwiftUI

extension Language {
    /// Every piece of text in this language uses this color, whoever said it,
    /// so each reader can find their language at a glance.
    var ink: Color { self == .english ? Color(.englishInk) : Color(.chineseInk) }
}

extension Font {
    /// Body text for transcripts, slightly larger than system body for reading across a table.
    static func transcript(_ language: Language, emphasized: Bool) -> Font {
        let base: Font = emphasized ? .title3 : .body
        return base.weight(emphasized ? .medium : .regular)
    }
}

/// A small capsule naming the language, e.g. "EN" or "中文".
struct LanguageTag: View {
    let language: Language
    var spoken = false

    var body: some View {
        HStack(spacing: 3) {
            if spoken {
                Image(systemName: "waveform")
                    .imageScale(.small)
            }
            Text(language.tag)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(language.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(language.ink.opacity(0.12), in: .capsule)
        .accessibilityLabel(spoken ? "Spoken in \(language.nativeName)" : "Translated to \(language.nativeName)")
    }
}

/// Three pulsing dots shown while text is on its way.
struct TypingDots: View {
    var color: Color = .secondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .accessibilityLabel("Working")
    }
}
