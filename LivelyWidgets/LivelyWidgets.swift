import SwiftUI
import WidgetKit

@main
struct LivelyWidgets: WidgetBundle {
    var body: some Widget {
        LivelyWidget()
    }
}

/// Starts a conversation from the home or lock screen: tapping opens Lively
/// and starts listening. It shows the language pair chosen in the app.
struct LivelyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetLanguages.widgetKind, provider: LanguagesProvider()) { entry in
            LivelyWidgetView(languages: entry.languages)
        }
        .configurationDisplayName("Translate")
        .description("Start translating a conversation with one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LanguagesEntry: TimelineEntry {
    let date: Date
    let languages: WidgetLanguages
}

/// One entry that never expires; the app reloads it when the pair changes.
struct LanguagesProvider: TimelineProvider {
    func placeholder(in context: Context) -> LanguagesEntry {
        LanguagesEntry(date: .now, languages: .fallback)
    }

    func getSnapshot(in context: Context, completion: @escaping (LanguagesEntry) -> Void) {
        completion(LanguagesEntry(date: .now, languages: .current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LanguagesEntry>) -> Void) {
        completion(Timeline(entries: [LanguagesEntry(date: .now, languages: .current)], policy: .never))
    }
}

struct LivelyWidgetView: View {
    let languages: WidgetLanguages
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetLanguages.listenURL)
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { Color(.canvas) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicBadge(size: 44)
            Spacer(minLength: 8)
            pair(font: .headline)
            Text("Tap to translate")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Lively", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.lively)
                    .widgetAccentable()
                Spacer(minLength: 8)
                pair(font: .title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                Link(destination: WidgetLanguages.listenURL) {
                    WidgetButton(title: "Listen", systemImage: "mic.fill", prominent: true)
                }
                Link(destination: WidgetLanguages.typeURL) {
                    WidgetButton(title: "Type", systemImage: "keyboard", prominent: false)
                }
            }
            .frame(width: 128)
        }
    }

    /// The two languages, each in its ink, one above the other so long names fit.
    private func pair(font: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(languages.firstName)
                .foregroundStyle(Color(.firstLanguageInk))
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(languages.secondName)
                    .foregroundStyle(Color(.secondLanguageInk))
            }
        }
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(languages.firstName) and \(languages.secondName)")
    }

    // MARK: - Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                Text("\(languages.firstTag)⇄\(languages.secondTag)")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Translate \(languages.firstName) and \(languages.secondName)")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Lively", systemImage: "mic.fill")
                .font(.headline)
                .widgetAccentable()
            Text("\(languages.firstName) ⇄ \(languages.secondName)")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Tap to translate")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label("\(languages.firstTag) ⇄ \(languages.secondTag)", systemImage: "mic.fill")
    }
}

/// The mic in an accent circle, like the app's mic button.
private struct MicBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.lively, in: .circle)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private struct WidgetButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let prominent: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Color.lively))
            .background(prominent ? Color.lively : Color.lively.opacity(0.14), in: .capsule)
            .widgetAccentable(prominent)
    }
}

#Preview(as: .systemSmall) { LivelyWidget() } timeline: { LanguagesEntry(date: .now, languages: .fallback) }
#Preview(as: .systemMedium) { LivelyWidget() } timeline: { LanguagesEntry(date: .now, languages: .fallback) }
#Preview(as: .accessoryCircular) { LivelyWidget() } timeline: { LanguagesEntry(date: .now, languages: .fallback) }
#Preview(as: .accessoryRectangular) { LivelyWidget() } timeline: { LanguagesEntry(date: .now, languages: .fallback) }

private extension Color {
    /// Lively's purple. Widgets don't pick up the global accent color, so it's named here.
    static let lively = Color("AccentColor")
}
