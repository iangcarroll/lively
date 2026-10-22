import SwiftUI

/// One turn, shown chat-style: speakers of the pair's first language on the
/// leading side, the second language on the trailing side, each bubble tinted with the
/// speaker's language color. The spoken text sits on top; the translation,
/// which the other person reads, is larger and in its own language's color.
struct UtteranceBubble: View {
    let utterance: Utterance
    var onRetry: () -> Void = {}
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private var spoken: Language { utterance.language }
    private var leading: Bool { spoken == utterance.languages.first }

    var body: some View {
        HStack {
            if !leading { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                block(spoken, text: utterance.trimmedSource, spoken: true)
                Divider().overlay(spoken.ink.opacity(0.2))
                translation
            }
            .padding(14)
            .background {
                // The speaker's color marks whose turn it was.
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                shape.fill(Color(.card))
                shape.fill(spoken.ink.opacity(0.08))
                shape.strokeBorder(spoken.ink.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .contextMenu {
                Button("Copy \(spoken.nativeName)", systemImage: "doc.on.doc") {
                    Clipboard.copy(utterance.trimmedSource)
                }
                if !utterance.translation.isEmpty {
                    Button("Copy \(utterance.target.nativeName)", systemImage: "doc.on.doc") {
                        Clipboard.copy(utterance.translation)
                    }
                }
                if let onEdit, utterance.isFinal {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                }
                if let onDelete {
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
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
                    .foregroundStyle(spoken ? AnyShapeStyle(.primary) : AnyShapeStyle(language.ink))
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
        let target = utterance.target
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
