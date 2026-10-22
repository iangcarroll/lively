import SwiftUI

/// Narrow layout: a single chat-style feed.
struct ChatTranscript: View {
    let store: ConversationStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.visibleUtterances) { utterance in
                    UtteranceBubble(utterance: utterance) { store.retryTranslation(utterance) }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.snappy, value: store.visibleUtterances.count)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Wide layout (iPhone Duo unfolded, landscape, iPad, Mac): English and
/// Chinese in side-by-side columns, one row per turn. Each person reads
/// straight down their own column.
struct ParallelTranscript: View {
    let store: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header(.english)
                header(.chinese)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleUtterances) { utterance in
                        ParallelRow(utterance: utterance) { store.retryTranslation(utterance) }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        Divider().opacity(0.4)
                    }
                }
                .padding(.horizontal, 20)
                .animation(.snappy, value: store.visibleUtterances.count)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    private func header(_ language: Language) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(language.ink).frame(width: 18, height: 4)
            Text(language.nativeName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(language.ink)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

private struct ParallelRow: View {
    let utterance: Utterance
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(.english)
            cell(.chinese)
        }
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.25), value: utterance.translation)
    }

    private func cell(_ language: Language) -> some View {
        let spoken = utterance.language == language
        let text = utterance.text(in: language)
        return VStack(alignment: .leading, spacing: 6) {
            LanguageTag(language: language, spoken: spoken)
            if text.isEmpty {
                failureOrDots(language)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(text)
                        .font(.title3.weight(spoken ? .regular : .medium))
                        .foregroundStyle(spoken ? AnyShapeStyle(.primary) : AnyShapeStyle(language.ink))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if spoken && !utterance.isFinal { TypingDots(color: language.ink) }
                }
                if !spoken { failureOrNothing }
            }
        }
        .environment(\.locale, language.locale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background {
            if spoken {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(language.ink.opacity(0.06))
                    .padding(.vertical, -8)
            }
        }
    }

    @ViewBuilder
    private func failureOrDots(_ language: Language) -> some View {
        switch utterance.translationState {
        case .failed, .waitingForNetwork: failureOrNothing
        default: TypingDots(color: language.ink).padding(.top, 6)
        }
    }

    @ViewBuilder
    private var failureOrNothing: some View {
        switch utterance.translationState {
        case .waitingForNetwork:
            Label("Waiting for connection", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Button(action: onRetry) {
                Label("\(message) · Retry", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(.orange)
        default:
            EmptyView()
        }
    }
}

struct EmptyConversation: View {
    var isListening: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(isListening ? "Listening. Go ahead and talk." : "Tap the mic to start")
                    .font(.title3.weight(.semibold))
                Text(isListening ? "正在听，说中文或英文都可以" : "点麦克风开始")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Language.chinese.ink)
            }
            .contentTransition(.opacity)
            .animation(.snappy, value: isListening)
            Text("Lively hears English and Chinese and translates both ways. No need to say who's speaking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
    }
}
