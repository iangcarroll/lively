import SwiftUI

extension Language {
    /// Every piece of text in this language uses this color, whoever said it,
    /// so each reader can find their language at a glance. The color follows
    /// the language's place in the chosen pair.
    var ink: Color {
        self == AppSettings.shared.languages.second ? Color(.secondLanguageInk) : Color(.firstLanguageInk)
    }
}

extension Font {
    /// Body text for transcripts, slightly larger than system body for reading across a table.
    static func transcript(_ language: Language, emphasized: Bool) -> Font {
        let base: Font = emphasized ? .title3 : .body
        return base.weight(emphasized ? .medium : .regular)
    }
}

/// A small capsule naming the language, e.g. "EN" or "中文". What was
/// actually said gets a solid capsule with a waveform; a translation gets a
/// light one with a translate icon, so the two never look alike.
struct LanguageTag: View {
    let language: Language
    var spoken = false
    /// Off for labels that name a language without saying how the text got there.
    var showsIcon = true

    var body: some View {
        HStack(spacing: 3) {
            if showsIcon {
                Image(systemName: spoken ? "waveform" : "translate")
                    .imageScale(.small)
            }
            Text(language.tag)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(spoken ? AnyShapeStyle(.white) : AnyShapeStyle(language.ink))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(spoken ? language.ink : language.ink.opacity(0.12), in: .capsule)
        .accessibilityLabel(!showsIcon ? language.nativeName : spoken ? "Spoken in \(language.nativeName)" : "Translated to \(language.nativeName)")
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
