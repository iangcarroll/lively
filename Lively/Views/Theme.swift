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

/// The iPhone Duo shows its camera, clock and status icons in a column down
/// one side instead of a bar across the top. iOS reports the whole column as
/// a side safe area inset, but only its top holds anything, so screens let
/// content below it use the full width and put their own controls in it,
/// below the status icons.
nonisolated struct StatusColumn: Equatable, Sendable {
    let edge: HorizontalEdge
    let width: CGFloat
    /// How far down the camera, clock and status icons reach. iOS doesn't
    /// report it, so this matches the iPhone Duo: folded, the camera sits
    /// above the clock; unfolded, the screen is landscape and the column
    /// holds only the clock and status icons.
    let itemsHeight: CGFloat

    /// The status icons sit a little in from the column's middle, away from
    /// the screen edge. Controls in the column leave this much room on the
    /// edge side so they line up under them.
    static let itemsInset: CGFloat = 12

    /// The column a view's size and safe area describe, if any: an inset on
    /// one side only. Landscape phones inset both sides for the notch, and
    /// that runs the full height, so it isn't a column.
    init?(size: CGSize, insets: EdgeInsets) {
        guard insets.top == 0 else { return nil }
        if insets.trailing > 0, insets.leading == 0 {
            edge = .trailing
            width = insets.trailing
        } else if insets.leading > 0, insets.trailing == 0 {
            edge = .leading
            width = insets.leading
        } else {
            return nil
        }
        itemsHeight = size.height > size.width ? 160 : 108
    }

    /// The column's side as a set of edges, for padding and safe areas.
    var edges: Edge.Set { edge == .trailing ? .trailing : .leading }

    /// How far from the screen edge the status icons' center line runs.
    var itemsCenter: CGFloat { Self.itemsInset + (width - Self.itemsInset) / 2 }

    /// The padding from the screen edge that centers a control this wide
    /// under the status icons, for rows that span the column.
    func inset(centering controlWidth: CGFloat) -> CGFloat {
        itemsCenter - controlWidth / 2
    }
}

extension EnvironmentValues {
    /// The iPhone Duo's status column, for views inside a screen that spans it.
    @Entry var statusColumn: StatusColumn?
}
