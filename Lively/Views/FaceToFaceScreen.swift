import SwiftUI

/// The phone layout: lay the phone flat between two people. The top half is
/// upside down so the person across the table reads it the right way up;
/// the bottom half faces the person holding the phone. Each half shows only
/// its reader's language. Controls sit in the middle so either person can reach them.
struct FaceToFaceScreen: View {
    let store: ConversationStore
    let languages: LanguagePair
    /// Language of the person on the near (bottom) side.
    @Binding var nearLanguage: Language
    let showsTextInput: Bool
    var textInputFocused: FocusState<Bool>.Binding
    var onSetTextInput: (Bool) -> Void
    @Binding var editing: Utterance?
    /// Corrects one of the near person's own turns.
    var onEdit: (Utterance) -> Void
    var onShowTranscript: () -> Void
    var onShowSettings: () -> Void
    /// The iPhone Duo's status column, which this screen spans: only the far
    /// half, beside its status icons, keeps clear of it.
    var statusColumn: StatusColumn?
    /// Small screens get tighter spacing, so the mic stays centered.
    @State private var narrow = false

    var body: some View {
        VStack(spacing: 0) {
            FaceToFaceHalf(store: store, language: languages.other(than: nearLanguage))
                .rotationEffect(.degrees(180))
                .padding(statusColumn?.edges ?? [], statusColumn?.width ?? 0)
            controlStrip
            FaceToFaceHalf(store: store, language: nearLanguage, onEdit: onEdit)
                .safeAreaBar(edge: .bottom) {
                    if showsTextInput {
                        // The near person types; the far side reads the translation.
                        TypeToTranslateBar(
                            store: store, languages: languages, language: nearLanguage,
                            editing: $editing, focused: textInputFocused
                        ) { onSetTextInput(false) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
        }
        .animation(.snappy, value: nearLanguage)
    }

    private var controlStrip: some View {
        HStack(spacing: narrow ? 8 : 12) {
            HStack(spacing: narrow ? 6 : 10) {
                // Never truncated: on narrow screens it keeps its width over the spacing.
                StatusPill(status: store.status, isListening: store.isListening, compact: true)
                    .fixedSize()
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
                    Button("Transcript View", systemImage: "list.bullet", action: onShowTranscript)
                    Button("Swap Sides", systemImage: "arrow.up.arrow.down") {
                        nearLanguage = languages.other(than: nearLanguage)
                    }
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
    let language: Language
    /// Set on the near half, whose reader can correct their own turns.
    var onEdit: ((Utterance) -> Void)?
    /// The newest line's size and the size older lines settle to.
    @ScaledMetric(relativeTo: .title) private var largestSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var smallestSize: CGFloat = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let recent = Array(store.visibleUtterances.suffix(12))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, utterance in
                    line(utterance, age: recent.count - 1 - index)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .animation(.snappy, value: store.visibleUtterances.count)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay {
            if store.visibleUtterances.isEmpty { emptyState }
        }
        // Older lines scroll away under a fade, clear of the tag.
        .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) {
            LanguageTag(language: language, showsIcon: false)
                .padding([.horizontal, .top], 14)
        }
        .environment(\.locale, language.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func line(_ utterance: Utterance, age: Int) -> some View {
        let text = utterance.text(in: language)
        // Your own words are quiet; what the other person said is prominent.
        let ownWords = utterance.language == language
        // Lines shrink and fade over a few turns rather than all at once, so a
        // line still being read stays legible when a stray turn lands below it.
        let prominence = max(0, 1 - Double(age) / 3)
        let size = smallestSize + (largestSize - smallestSize) * prominence
        let weight: Font.Weight = !ownWords && age < 2 ? .semibold : .regular
        VStack(alignment: .leading, spacing: 4) {
            if text.isEmpty {
                TypingDots(color: language.ink)
                    .padding(.vertical, 8)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(text)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(ownWords ? AnyShapeStyle(.secondary) : AnyShapeStyle(language.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    if ownWords && !utterance.isFinal { TypingDots(color: language.ink) }
                }
            }
            if !ownWords { statusLine(utterance) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.55 + 0.45 * prominence)
        .animation(.snappy(duration: 0.25), value: text)
        .animation(.snappy, value: age)
        .modifier(EditMenu(utterance: utterance, onEdit: ownWords ? onEdit : nil))
    }

    @ViewBuilder
    private func statusLine(_ utterance: Utterance) -> some View {
        switch utterance.translationState {
        case .waitingForNetwork:
            Label(language.phrases.waitingForConnection, systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button {
                store.retryTranslation(utterance)
            } label: {
                Label(language.phrases.translationFailed, systemImage: "arrow.clockwise")
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
            Text(store.isConnecting ? language.phrases.connecting
                 : store.isListening ? language.phrases.listening : language.phrases.tapToStart)
                .font(.title2.weight(.semibold))
                .foregroundStyle(language.ink)
                .contentTransition(.opacity)
                .animation(.snappy, value: store.isListening)
                .animation(.snappy, value: store.isConnecting)
            Text(language.phrases.speakHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
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
