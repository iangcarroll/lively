import SwiftUI

/// The phone layout: lay the phone flat between two people. The top half is
/// upside down so the person across the table reads it the right way up;
/// the bottom half faces the person holding the phone. Each half shows only
/// its reader's language. Controls sit in the middle so either person can reach them.
struct FaceToFaceScreen: View {
    let store: ConversationStore
    let languages: LanguagePair?
    /// Language of the person on the near (bottom) side.
    @Binding var nearLanguage: Language
    @Binding var listenerNear: Bool
    let showsTextInput: Bool
    var textInputFocused: FocusState<Bool>.Binding
    var onSetTextInput: (Bool) -> Void
    @Binding var editing: Utterance?
    /// Corrects one of the near person's own turns.
    var onEdit: (Utterance) -> Void
    var onShowTranscript: () -> Void
    var onShowSettings: () -> Void
    var onShowAddress: () -> Void
    /// The iPhone Duo's status column, which this screen spans: only the far
    /// half, beside its status icons, keeps clear of it.
    var statusColumn: StatusColumn?
    var showsListeningPrompt = true
    /// Small screens get tighter spacing, so the mic stays centered.
    @State private var narrow = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            FaceToFaceHalf(store: store, language: farDisplayLanguage, role: farRole, showsListeningPrompt: showsListeningPrompt)
                .rotationEffect(.degrees(180))
                .padding(statusColumn?.edges ?? [], statusColumn?.width ?? 0)
            controlStrip
            ConversationTranscriptLayout {
                EmptyView()
            } transcript: {
                FaceToFaceHalf(store: store, language: nearDisplayLanguage, role: nearRole, onEdit: onEdit, showsListeningPrompt: showsListeningPrompt)
            } footer: {
                if showsTextInput {
                    // The near person types; the far side reads the translation.
                    TypeToTranslateBar(
                        store: store, languages: languages, language: nearDisplayLanguage ?? store.listenerLanguage,
                        editing: $editing, focused: textInputFocused
                    ) { onSetTextInput(false) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy, value: nearLanguage)
        .animation(.snappy, value: listenerNear)
    }

    private var nearRole: TranscriptRole? {
        store.isAutomaticLanguageMode ? (listenerNear ? .listener : .partner) : nil
    }
    private var farRole: TranscriptRole? {
        store.isAutomaticLanguageMode ? (listenerNear ? .partner : .listener) : nil
    }
    private var nearDisplayLanguage: Language? {
        guard store.isAutomaticLanguageMode else { return nearLanguage }
        return listenerNear ? store.listenerLanguage : store.detectedPartnerLanguage
    }
    private var farDisplayLanguage: Language? {
        guard store.isAutomaticLanguageMode else { return languages?.other(than: nearLanguage) }
        return listenerNear ? store.detectedPartnerLanguage : store.listenerLanguage
    }

    private var controlStrip: some View {
        VStack(spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                StatusPill(status: store.status, isListening: store.isListening, compact: true, onDevice: store.isUsingOnDevice)
            }
            HStack(spacing: narrow ? 8 : 12) {
                HStack(spacing: narrow ? 6 : 10) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        StatusPill(status: store.status, isListening: store.isListening, compact: true, onDevice: store.isUsingOnDevice)
                            .fixedSize()
                    }
                    GlassIconButton(systemImage: showsTextInput ? "keyboard.chevron.compact.down" : "keyboard", label: "Type to translate") {
                        onSetTextInput(!showsTextInput)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MicButton(isListening: store.isListening, level: store.level, isHearing: store.isHearing) {
                    store.toggleListening()
                } onHoldStart: {
                    store.startListening()
                } onHoldEnd: {
                    store.stopListening()
                }
                HStack(spacing: narrow ? 6 : 10) {
                    GlassIconButton(systemImage: "trash", label: "Clear conversation") {
                        withAnimation(.snappy) { store.clear() }
                    }
                    .disabled(store.utterances.isEmpty)
                    .opacity(store.utterances.isEmpty ? 0.4 : 1)
                    Menu {
                        Button("Address", systemImage: "mappin.and.ellipse", action: onShowAddress)
                        Divider()
                        Button("Transcript View", systemImage: "list.bullet", action: onShowTranscript)
                        Button("Swap Sides", systemImage: "arrow.up.arrow.down") {
                            if store.isAutomaticLanguageMode { listenerNear.toggle() }
                            else if let languages { nearLanguage = languages.other(than: nearLanguage) }
                        }
                        SpeakAloudToggle(store: store)
                        Divider()
                        Button("Settings", systemImage: "gearshape", action: onShowSettings)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: GlassIconButton.size, height: GlassIconButton.size)
                            .contentShape(.circle)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("More")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // Beside the iPhone Duo's status column, the More button sits under its
        // status icons; both sides match, so the mic stays centered.
        .padding(.horizontal, statusColumn?.inset(centering: GlassIconButton.size) ?? (narrow ? 12 : 16))
        .padding(.vertical, 8)
        .onGeometryChange(for: Bool.self) { $0.size.width < 400 } action: { narrow = $0 }
        .background {
            // Hairlines separate the two readers' halves.
            // They run edge to edge, through any side inset.
            VStack {
                Divider()
                Spacer()
                Divider()
            }
            .ignoresSafeArea(edges: .horizontal)
        }
    }
}

/// One reader's half: the conversation in their language, newest line largest
/// and nearest their edge of the phone.
private struct FaceToFaceHalf: View {
    let store: ConversationStore
    let language: Language?
    var role: TranscriptRole?
    /// Set on the near half, whose reader can correct their own turns.
    var onEdit: ((Utterance) -> Void)?
    var showsListeningPrompt = true
    /// The newest line's size and the size older lines settle to.
    @ScaledMetric(relativeTo: .title) private var largestSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var smallestSize: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ConversationTranscriptLayout {
            header
        } transcript: {
            transcript
        } footer: {
            if !store.visibleUtterances.isEmpty && showsListeningPrompt {
                Text(emptyPrompt).font(.headline)
                    .foregroundStyle(language?.ink ?? .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background((language?.ink ?? .secondary).opacity(0.06))
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsListeningPrompt)
        .environment(\.locale, language?.locale ?? .current)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let recent = Array(store.visibleUtterances.suffix(12))
                    if recent.isEmpty {
                        emptyState.frame(maxWidth: .infinity)
                            .opacity(showsListeningPrompt ? 1 : 0)
                            .accessibilityHidden(!showsListeningPrompt)
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, utterance in
                        line(utterance, age: recent.count - 1 - index)
                            .id(utterance.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .animation(.snappy, value: store.visibleUtterances.count)
            }
            .defaultScrollAnchor(store.visibleUtterances.isEmpty ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .followsNewest(readerUtterances, proxy: proxy)
        }
    }

    private var readerUtterances: [Utterance] {
        // Source-only turns have no listener line to scroll to.
        store.visibleUtterances.suffix(12).filter { !($0.isSourceOnly && role == .listener) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let role {
                Text(role == .listener ? "Your language" : "Other language")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            OptionalLanguageTag(language: language, showsIcon: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 14)
    }

    @ViewBuilder
    private func line(_ utterance: Utterance, age: Int) -> some View {
        let rowLanguage: Language? = if let role { role.language(in: utterance) } else { language }
        let neutral = utterance.isAutomatic && utterance.sourceLanguage == nil && utterance.target == nil
        let text = role?.text(in: utterance) ?? language.map { utterance.text(in: $0) } ?? ""
        // Your own words are quiet; what the other person said is prominent.
        let ownWords = role?.isSource(in: utterance) ?? (utterance.sourceLanguage == language)
        let ink = neutral ? Color.secondary : (rowLanguage?.ink ?? .secondary)
        // Lines shrink and fade over a few turns rather than all at once, so a
        // line still being read stays legible when a stray turn lands below it.
        let prominence = max(0, 1 - Double(age) / 3)
        let size = smallestSize + (largestSize - smallestSize) * prominence
        let weight: Font.Weight = !ownWords && age < 2 ? .semibold : .regular
        if !(utterance.isSourceOnly && role == .listener) {
            VStack(alignment: .leading, spacing: 4) {
                if role != nil && (neutral || rowLanguage != language) {
                    OptionalLanguageTag(language: neutral ? nil : rowLanguage, spoken: ownWords, unknownTitle: neutral ? utterance.unidentifiedLanguageTitle : "Automatic")
                }
                if text.isEmpty {
                    if !ownWords && !neutral && utterance.hasTranslationProblem {
                        statusLine(utterance, language: rowLanguage)
                    } else if utterance.showsLanguagePrompt {
                        PendingLanguageLabel(utterance: utterance, onTranslate: { store.retryTranslation(utterance) })
                    } else if utterance.isFinal && ((ownWords && utterance.source.isEmpty) || rowLanguage == nil) {
                        Text("—")
                            .font(.system(size: size, weight: weight))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Original transcript unavailable")
                    } else {
                        TypingDots(color: ink)
                            .padding(.vertical, 8)
                    }
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(text)
                            .font(.system(size: size, weight: weight))
                            .foregroundStyle(ownWords ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink))
                            .fixedSize(horizontal: false, vertical: true)
                        if ownWords && !utterance.isFinal { TypingDots(color: ink) }
                    }
                }
                if !utterance.isSourceOnly && !neutral && !text.isEmpty && (!ownWords || utterance.hasTranslationProblem) {
                    statusLine(utterance, language: rowLanguage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0.55 + 0.45 * prominence)
            .animation(.snappy(duration: 0.25), value: text)
            .animation(.snappy, value: age)
            .environment(\.locale, rowLanguage?.locale ?? .current)
            .modifier(EditMenu(utterance: utterance, onEdit: ownWords ? onEdit : nil))
        }
    }

    @ViewBuilder
    private func statusLine(_ utterance: Utterance, language: Language?) -> some View {
        switch utterance.translationState {
        case .awaitingPartner:
            PendingLanguageLabel(utterance: utterance, onTranslate: { store.retryTranslation(utterance) })
        case .waitingForNetwork:
            Label(language?.phrases.waitingForConnection ?? "Waiting for connection", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button {
                store.retryTranslation(utterance)
            } label: {
                Label(language?.phrases.translationFailed ?? "Translation failed", systemImage: "arrow.clockwise")
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
            Text(emptyPrompt)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(language?.ink ?? .secondary)
                .contentTransition(.opacity)
                .animation(.snappy, value: store.isListening)
                .animation(.snappy, value: store.isConnecting)
            Text(emptyHint)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 24)
    }

    private var emptyPrompt: String {
        if store.isAutomaticLanguageMode && !store.isOnline { return "Automatic detection needs internet" }
        guard let language else { return store.isListening ? "Listening for another language" : "Automatic" }
        if store.isListening && store.status == .offline { return language.phrases.waitingForConnection }
        return store.isConnecting ? language.phrases.connecting
            : store.isListening ? language.phrases.listening : language.phrases.tapToStart
    }

    private var emptyHint: String {
        if store.isAutomaticLanguageMode && !store.isOnline { return "Choose a language pair in Settings for on-device translation." }
        return language?.phrases.speakHint ?? "The other language will appear when they speak."
    }
}

/// Long-press to correct a finished turn's transcript, where editing is offered.
private struct EditMenu: ViewModifier {
    let utterance: Utterance
    let onEdit: ((Utterance) -> Void)?

    func body(content: Content) -> some View {
        if let onEdit, utterance.isFinal {
            content.contextMenu {
                Button("Edit", systemImage: "pencil") { onEdit(utterance) }
            }
        } else {
            content
        }
    }
}
