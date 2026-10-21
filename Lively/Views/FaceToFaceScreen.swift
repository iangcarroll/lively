import SwiftUI

/// The phone layout: lay the phone flat between two people. The top half is
/// upside down so the person across the table reads it the right way up;
/// the bottom half faces the person holding the phone. Each half shows only
/// its reader's language. Controls sit in the middle so either person can reach them.
struct FaceToFaceScreen: View {
    let store: ConversationStore
    /// Language of the person on the near (bottom) side.
    @Binding var nearLanguage: Language
    var onShowTranscript: () -> Void
    var onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FaceToFaceHalf(store: store, language: nearLanguage.other)
                .rotationEffect(.degrees(180))
            controlStrip
            FaceToFaceHalf(store: store, language: nearLanguage)
        }
        .animation(.snappy, value: nearLanguage)
    }

    private var controlStrip: some View {
        HStack(spacing: 12) {
            StatusPill(status: store.status, isListening: store.isListening, compact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            MicButton(isListening: store.isListening, level: store.level) {
                store.toggleListening()
            }
            HStack(spacing: 10) {
                GlassIconButton(systemImage: "arrow.up.arrow.down", label: "Swap sides") {
                    nearLanguage = nearLanguage.other
                }
                Menu {
                    Button("Transcript View", systemImage: "list.bullet", action: onShowTranscript)
                    Button("Clear Conversation", systemImage: "trash", role: .destructive) {
                        withAnimation(.snappy) { store.clear() }
                    }
                    .disabled(store.utterances.isEmpty)
                    Divider()
                    Button("Settings", systemImage: "gearshape", action: onShowSettings)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("More")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            // Hairlines separate the two readers' halves.
            VStack {
                Divider()
                Spacer()
                Divider()
            }
        }
    }
}

/// One reader's half: the conversation in their language, newest line largest
/// and nearest their edge of the phone.
private struct FaceToFaceHalf: View {
    let store: ConversationStore
    let language: Language

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let recent = Array(store.utterances.suffix(12))
                ForEach(recent) { utterance in
                    line(utterance, isLatest: utterance === recent.last)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .animation(.snappy, value: store.utterances.count)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.hidden)
        .overlay {
            if store.utterances.isEmpty { emptyState }
        }
        .overlay(alignment: .topLeading) {
            LanguageTag(language: language).padding(14)
        }
        .environment(\.locale, language.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func line(_ utterance: Utterance, isLatest: Bool) -> some View {
        let text = utterance.text(in: language)
        // Your own words are quiet; what the other person said is prominent.
        let ownWords = utterance.language == language
        VStack(alignment: .leading, spacing: 4) {
            if text.isEmpty {
                TypingDots(color: language.ink)
                    .padding(.vertical, 8)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(text)
                        .font(isLatest ? .title.weight(ownWords ? .regular : .semibold) : .title3)
                        .foregroundStyle(ownWords ? AnyShapeStyle(.secondary) : AnyShapeStyle(language.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    if ownWords && !utterance.isFinal { TypingDots(color: language.ink) }
                }
            }
            if !ownWords { statusLine(utterance) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isLatest ? 1 : 0.55)
        .animation(.snappy(duration: 0.25), value: text)
    }

    @ViewBuilder
    private func statusLine(_ utterance: Utterance) -> some View {
        switch utterance.translationState {
        case .waitingForNetwork:
            Label(language == .english ? "Waiting for connection" : "等待网络连接", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button {
                store.retryTranslation(utterance)
            } label: {
                Label(language == .english ? "Translation failed · Retry" : "翻译失败 · 重试", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(.orange)
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(language == .english ? "Just start talking" : "请直接说话")
                .font(.title2.weight(.semibold))
                .foregroundStyle(language.ink)
            Text(language == .english
                 ? "Speak English. Lively translates for the other person."
                 : "说中文就可以，Lively 会翻译给对方。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
