import SwiftUI

/// One turn, shown chat-style: English speakers on the leading side,
/// Chinese speakers on the trailing side. The spoken text sits on top in a
/// quieter style; the translation, which the other person reads, is larger.
struct UtteranceBubble: View {
    let utterance: Utterance
    var onRetry: () -> Void = {}

    private var spoken: Language { utterance.language }
    private var leading: Bool { spoken == .english }

    var body: some View {
        HStack {
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                block(spoken, text: utterance.trimmedSource, spoken: true)
                Divider().opacity(0.5)
                translation
            }
            .padding(14)
            .background(Color(.card), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(alignment: leading ? .leading : .trailing) {
                // A sliver of the speaker's color marks whose turn it was.
                Capsule()
                    .fill(spoken.ink)
                    .frame(width: 3)
                    .padding(.vertical, 16)
                    .offset(x: leading ? -1.5 : 1.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .contextMenu {
                Button("Copy \(spoken.nativeName)", systemImage: "doc.on.doc") {
                    Clipboard.copy(utterance.trimmedSource)
                }
                if !utterance.translation.isEmpty {
                    Button("Copy \(spoken.other.nativeName)", systemImage: "doc.on.doc") {
                        Clipboard.copy(utterance.translation)
                    }
                }
            }
            if leading { Spacer(minLength: 40) }
        }
        .animation(.snappy(duration: 0.25), value: utterance.translation)
        .animation(.snappy(duration: 0.25), value: utterance.language)
    }

    private func block(_ language: Language, text: String, spoken: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LanguageTag(language: language, spoken: spoken)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(text)
                    .font(.transcript(language, emphasized: !spoken))
                    .foregroundStyle(spoken ? AnyShapeStyle(.secondary) : AnyShapeStyle(language.ink))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if spoken && !utterance.isFinal {
                    TypingDots(color: language.ink)
                }
            }
        }
        .environment(\.locale, language.locale)
    }

    @ViewBuilder
    private var translation: some View {
        let target = spoken.other
        if !utterance.translation.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                block(target, text: utterance.translation, spoken: false)
                    .opacity(utterance.translationState == .current || utterance.isFinal ? 1 : 0.75)
                statusLine
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                LanguageTag(language: target)
                statusLine
                if case .working = utterance.translationState { TypingDots(color: target.ink) }
                else if case .idle = utterance.translationState { TypingDots(color: target.ink) }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch utterance.translationState {
        case .waitingForNetwork:
            Label("Waiting for connection", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Button(action: onRetry) {
                Label("\(message) · Retry", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(.orange)
        default:
            if utterance.isLate {
                Label("Caught up after a dropout", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
