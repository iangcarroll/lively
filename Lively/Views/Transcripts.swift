import SwiftUI

/// Narrow layout: a single chat-style feed. A list, not a scroll view, so
/// turns can be swiped away.
struct ChatTranscript: View {
    let store: ConversationStore

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store.visibleUtterances) { utterance in
                    UtteranceBubble(
                        utterance: utterance,
                        onRetry: { store.retryTranslation(utterance) },
                        onDelete: { delete(utterance, from: store) }
                    )
                    .transcriptRow(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeToDelete { delete(utterance, from: store) }
                }
            }
            .transcriptList()
            .animation(.snappy, value: store.visibleUtterances.count)
            .followsNewest(store.visibleUtterances, proxy: proxy)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Wide layout (iPhone Duo unfolded, landscape, iPad, Mac): the two
/// languages in side-by-side columns, one row per turn. Each person reads
/// straight down their own column.
struct ParallelTranscript: View {
    let store: ConversationStore
    var languages: LanguagePair { AppSettings.shared.languages }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header(languages.first)
                header(languages.second)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                List {
                    ForEach(store.visibleUtterances) { utterance in
                        ParallelRow(utterance: utterance) { store.retryTranslation(utterance) }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(utterance, from: store) }
                            }
                            .transcriptRow(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20), separator: true)
                            .swipeToDelete { delete(utterance, from: store) }
                    }
                }
                .transcriptList()
                .animation(.snappy, value: store.visibleUtterances.count)
                .followsNewest(store.visibleUtterances, proxy: proxy)
            }
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

private func delete(_ utterance: Utterance, from store: ConversationStore) {
    withAnimation(.snappy) { store.delete(utterance) }
}

private extension View {
    /// A transcript turn as a bare list row: no background, and the
    /// separator only where a layout asks for one.
    func transcriptRow(_ insets: EdgeInsets, separator: Bool = false) -> some View {
        listRowInsets(insets)
            .listRowBackground(Color.clear)
            .listRowSeparator(separator ? .visible : .hidden)
            .listRowSeparatorTint(.secondary.opacity(0.4))
    }

    func swipeToDelete(_ action: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive, action: action)
        }
    }

    /// Keeps the newest turn in view as turns arrive and grow, like the
    /// bottom-anchored scroll view this list replaced.
    func followsNewest(_ utterances: [Utterance], proxy: ScrollViewProxy) -> some View {
        let last = utterances.last
        let growth = last.map { $0.trimmedSource.count + $0.translation.count } ?? 0
        return onAppear { if let last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: last?.id) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: growth) { _, _ in
                if let last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
    }

    func transcriptList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

private struct ParallelRow: View {
    let utterance: Utterance
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(utterance.languages.first)
            cell(utterance.languages.second)
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
    var languages: LanguagePair { AppSettings.shared.languages }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(prompt(in: languages.first))
                    .font(.title3.weight(.semibold))
                Text(prompt(in: languages.second))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(languages.second.ink)
            }
            .contentTransition(.opacity)
            .animation(.snappy, value: isListening)
            Text("Lively hears \(languages.first.englishName) and \(languages.second.englishName) and translates both ways. No need to say who's speaking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
    }

    private func prompt(in language: Language) -> String {
        isListening ? language.phrases.listening : language.phrases.tapToStart
    }
}
