import SwiftUI

/// Narrow layout: a single chat-style feed. A list, not a scroll view, so
/// turns can be swiped away.
struct ChatTranscript: View {
    let store: ConversationStore
    var onEdit: (Utterance) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store.visibleUtterances) { utterance in
                    UtteranceBubble(
                        utterance: utterance,
                        onRetry: { store.retryTranslation(utterance) },
                        onEdit: { onEdit(utterance) },
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
    var onEdit: (Utterance) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if store.isAutomaticLanguageMode {
                    header(store.listenerLanguage, role: "Your language")
                    header(store.detectedPartnerLanguage, role: "Other language")
                } else {
                    header(AppSettings.shared.languages.first)
                    header(AppSettings.shared.languages.second)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                List {
                    ForEach(store.visibleUtterances) { utterance in
                        ParallelRow(utterance: utterance) { store.retryTranslation(utterance) }
                            .contextMenu {
                                if utterance.isFinal {
                                    Button("Edit", systemImage: "pencil") { onEdit(utterance) }
                                }
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

    private func header(_ language: Language?, role: String? = nil) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(language?.ink ?? .secondary).frame(width: 18, height: 4)
            VStack(alignment: .leading, spacing: 2) {
                if let role { Text(role).font(.caption).foregroundStyle(.secondary) }
                Text(language?.nativeName ?? "Automatic")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(language?.ink ?? .secondary)
            }
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
            // Turns fade out under the top and bottom bars.
            .scrollEdgeEffectStyle(.soft, for: .vertical)
    }
}

private struct ParallelRow: View {
    let utterance: Utterance
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if utterance.isAutomatic {
                if utterance.isSourceOnly {
                    Color.clear.frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
                    cell(utterance.sourceLanguage, role: .partner)
                } else if utterance.sourceLanguage == nil && utterance.target == nil {
                    neutralCaption
                } else {
                    cell(TranscriptRole.listener.language(in: utterance), role: .listener)
                    cell(TranscriptRole.partner.language(in: utterance), role: .partner)
                }
            } else {
                cell(utterance.languages.first)
                cell(utterance.languages.second)
            }
        }
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.25), value: utterance.translation)
    }

    private func cell(_ language: Language?, role: TranscriptRole? = nil) -> some View {
        let spoken = role?.isSource(in: utterance) ?? (utterance.sourceLanguage == language)
        let text = role?.text(in: utterance) ?? language.map { utterance.text(in: $0) } ?? ""
        let ink = language?.ink ?? Color.secondary
        return VStack(alignment: .leading, spacing: 6) {
            OptionalLanguageTag(language: language, spoken: spoken)
            if text.isEmpty {
                if utterance.isFinal && !utterance.showsLanguagePrompt && ((spoken && utterance.source.isEmpty) || language == nil) {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Original transcript unavailable")
                } else {
                    failureOrDots(ink)
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(text)
                        .font(.title3.weight(spoken ? .regular : .medium))
                        .foregroundStyle(spoken ? AnyShapeStyle(.primary) : AnyShapeStyle(ink))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if spoken && !utterance.isFinal { TypingDots(color: ink) }
                }
                if !spoken { failureOrNothing }
            }
        }
        .environment(\.locale, language?.locale ?? .current)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background {
            if spoken {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ink.opacity(0.06))
                    .padding(.vertical, -8)
            }
        }
    }

    @ViewBuilder
    private func failureOrDots(_ ink: Color) -> some View {
        if utterance.showsLanguagePrompt {
            PendingLanguageLabel(utterance: utterance, onTranslate: onRetry)
        } else {
            switch utterance.translationState {
            case .failed, .waitingForNetwork: failureOrNothing
            default: TypingDots(color: ink).padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var failureOrNothing: some View {
        switch utterance.translationState {
        case .awaitingPartner:
            PendingLanguageLabel(utterance: utterance, onTranslate: onRetry)
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

    private var neutralCaption: some View {
        VStack(alignment: .leading, spacing: 6) {
            OptionalLanguageTag(language: nil, unknownTitle: utterance.unidentifiedLanguageTitle)
            Text(utterance.trimmedSource).font(.title3).textSelection(.enabled)
            PendingLanguageLabel(utterance: utterance, onTranslate: onRetry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

struct EmptyConversation: View {
    let store: ConversationStore
    var showsListeningPrompt = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isListening: Bool { store.isListening }
    private var isConnecting: Bool { store.isConnecting }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                VStack(spacing: 6) {
                    Text(prompt(in: store.isAutomaticLanguageMode ? store.listenerLanguage : AppSettings.shared.languages.first))
                        .font(.title3.weight(.semibold))
                    if store.isAutomaticLanguageMode {
                        if let partner = store.detectedPartnerLanguage {
                            Text(prompt(in: partner)).font(.title3.weight(.semibold)).foregroundStyle(partner.ink)
                        } else {
                            Text(isListening ? "Listening for another language" : "Other language · Automatic")
                                .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(prompt(in: AppSettings.shared.languages.second))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppSettings.shared.languages.second.ink)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.snappy, value: isListening)
                .animation(.snappy, value: isConnecting)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .opacity(showsListeningPrompt ? 1 : 0)
            .accessibilityHidden(!showsListeningPrompt)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsListeningPrompt)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollIndicators(.hidden)
    }

    private var explanation: String {
        if store.isAutomaticLanguageMode {
            return store.isOnline
                ? "Just talk. Lively detects the other language and translates both ways. Your side stays in \(store.listenerLanguage.englishName)."
                : "Automatic detection needs internet. Choose a language pair and the On-device engine in Settings to translate offline."
        }
        let languages = AppSettings.shared.languages
        return "Lively hears \(languages.first.englishName) and \(languages.second.englishName) and translates both ways. No need to say who's speaking."
    }

    private func prompt(in language: Language) -> String {
        isConnecting ? language.phrases.connecting
            : isListening ? language.phrases.listening : language.phrases.tapToStart
    }
}
