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

    private var spoken: Language? { utterance.sourceLanguage }
    private var ink: Color { spoken?.ink ?? .secondary }
    private var unclassified: Bool { utterance.isAutomatic && spoken == nil && utterance.target == nil }
    private var leading: Bool {
        utterance.isAutomatic ? spoken == utterance.listenerLanguage : spoken == utterance.languages.first
    }

    var body: some View {
        HStack {
            if !leading && !unclassified { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 10) {
                block(spoken, text: utterance.trimmedSource, spoken: true)
                if !utterance.isSourceOnly {
                    Divider().overlay(ink.opacity(0.2))
                    translation
                }
            }
            .padding(14)
            .background {
                // The speaker's color marks whose turn it was.
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                shape.fill(Color(.card))
                shape.fill(ink.opacity(0.08))
                shape.strokeBorder(ink.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .contextMenu {
                if !utterance.trimmedSource.isEmpty {
                    Button(spoken.map { String(localized: "Copy \($0.nativeName)") } ?? String(localized: "Copy original"), systemImage: "doc.on.doc") {
                        Clipboard.copy(utterance.trimmedSource)
                    }
                }
                if !utterance.translation.isEmpty {
                    Button(utterance.target.map { String(localized: "Copy \($0.nativeName)") } ?? String(localized: "Copy translation"), systemImage: "doc.on.doc") {
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
            if leading && !unclassified { Spacer(minLength: 40) }
        }
        .animation(.snappy(duration: 0.25), value: utterance.translation)
        .animation(.snappy(duration: 0.25), value: utterance.sourceLanguage)
    }

    private func block(_ language: Language?, text: String, spoken: Bool) -> some View {
        let missingSource = spoken && text.isEmpty && utterance.isFinal
        return VStack(alignment: .leading, spacing: 4) {
            OptionalLanguageTag(language: language, spoken: spoken, unknownTitle: spoken ? utterance.unidentifiedLanguageTitle : String(localized: "Automatic"))
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(missingSource ? "—" : text)
                    .font(.transcript(language ?? utterance.listenerLanguage, emphasized: !spoken))
                    .foregroundStyle(spoken ? AnyShapeStyle(.primary) : AnyShapeStyle(language?.ink ?? .secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(missingSource ? String(localized: "Original transcript unavailable") : text)
                if spoken && !utterance.isFinal {
                    TypingDots(color: language?.ink ?? .secondary)
                }
            }
        }
        .environment(\.locale, language?.locale ?? .current)
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
        } else if utterance.showsLanguagePrompt || target == nil {
            PendingLanguageLabel(utterance: utterance, onTranslate: onRetry)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                OptionalLanguageTag(language: target)
                statusLine
                if case .working = utterance.translationState { TypingDots(color: target?.ink ?? .secondary) }
                else if case .idle = utterance.translationState { TypingDots(color: target?.ink ?? .secondary) }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch utterance.translationState {
        case .awaitingPartner:
            PendingLanguageLabel(utterance: utterance, onTranslate: onRetry)
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
                Label("Delayed transcription", systemImage: "clock.arrow.circlepath")
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
