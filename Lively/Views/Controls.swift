import PhotosUI
import SwiftUI
import Translation

/// The one big button: start and stop listening. A ring breathes with the mic
/// level, and fades while the noise gate is holding back distant sound.
///
/// Tapping toggles listening. Holding it while stopped listens only until
/// it's let go, like a walkie-talkie.
struct MicButton: View {
    let isListening: Bool
    let level: Float
    var isHearing = true
    let action: () -> Void
    /// `onHoldStart` runs once a press has lasted `holdDelay`; `onHoldEnd` when it ends.
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}

    /// How long a press lasts before it counts as a hold rather than a tap.
    static let holdDelay = Duration.milliseconds(300)

    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    /// The release that ended a hold also reports a tap; this drops it.
    @State private var swallowsTap = false

    var body: some View {
        Button(action: tap) {
            ZStack {
                if isListening {
                    Circle()
                        .stroke(Color.accentColor.opacity(isHearing ? 0.35 : 0.12), lineWidth: 3)
                        .scaleEffect(1 + CGFloat(level) * 0.35)
                        .animation(.easeOut(duration: 0.12), value: level)
                        .animation(.easeOut(duration: 0.2), value: isHearing)
                }
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isListening ? .white : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 76, height: 76)
            .contentShape(.circle)
        }
        .buttonStyle(PressReportingStyle(onChange: pressChanged))
        .glassEffect(
            isListening ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: .circle
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
    }

    private func pressChanged(_ pressed: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        if pressed {
            swallowsTap = false
            // A hold only means something while stopped; otherwise it's a slow tap.
            guard !isListening else { return }
            holdTimer = Task {
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled else { return }
                isHolding = true
                onHoldStart()
            }
        } else if isHolding {
            // Released, possibly after sliding off the button.
            endHold()
            swallowsTap = true
        }
    }

    private func tap() {
        // The tap can arrive before or after the press ends.
        if isHolding { return endHold() }
        if swallowsTap {
            swallowsTap = false
            return
        }
        action()
    }

    private func endHold() {
        isHolding = false
        onHoldEnd()
    }
}

/// A plain button style that reports when it's pressed and released.
private struct PressReportingStyle: ButtonStyle {
    let onChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onChange(pressed) }
    }
}

struct StatusPill: View {
    let status: ConversationStore.ConnectionStatus
    let isListening: Bool
    /// Dot only, for tight spaces; the label is still read by VoiceOver.
    var compact = false
    /// The on-device engine is standing in for the chosen provider.
    var onDevice = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35], trigger: pulsing) { dot, phase in
                    dot.opacity(pulsing ? phase : 1)
                }
            if !compact || status != .live {
                Text(compact ? shortLabel : label)
                    .font(.footnote.weight(.medium))
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact && status == .live ? 9 : 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var pulsing: Bool {
        switch status {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var label: String {
        switch status {
        case .idle: "Ready"
        case .connecting: "Connecting…"
        case .live: onDevice ? "On-device" : "Listening"
        case .reconnecting: "Reconnecting…"
        case .offline: isListening ? "Offline · holding audio" : "Offline"
        case .failed: "Needs attention"
        }
    }

    private var shortLabel: String {
        switch status {
        case .offline: "Offline"
        case .reconnecting: "Reconnecting"
        case .connecting: "Connecting"
        default: label
        }
    }

    private var color: Color {
        switch status {
        case .idle: .secondary
        case .connecting, .reconnecting: .orange
        case .live: .green
        case .offline, .failed: .red
        }
    }
}

/// Stays beside the transcript controls after the empty-state guidance is gone.
/// Both readers can see that they can speak without touching the microphone.
struct TranscriptListeningStatus: View {
    let status: ConversationStore.ConnectionStatus
    let isListening: Bool
    let languages: LanguagePair

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt(in: languages.first))
                    .foregroundStyle(.primary)
                Text(prompt(in: languages.second))
                    .foregroundStyle(languages.second.ink)
            }
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(isListening ? 0.1 : 0.04), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func prompt(in language: Language) -> String {
        guard isListening else { return language.phrases.tapToStart }
        switch status {
        case .live: return language.phrases.listening
        case .offline: return language.phrases.waitingForConnection
        default: return language.phrases.connecting
        }
    }

    private var symbol: String {
        guard isListening else { return "mic.slash" }
        switch status {
        case .live: return "waveform"
        case .offline: return "wifi.slash"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        guard isListening else { return .secondary }
        return status == .offline ? .orange : .accentColor
    }
}

struct GlassIconButton: View {
    let systemImage: String
    let label: String
    /// Set for a toggle, which is tinted while on.
    var isOn: Bool?
    let action: () -> Void

    static let size: CGFloat = 40

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn == true ? .white : .primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn == true ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
        .help(label)
    }
}

/// The menu item that switches speech-to-speech mode. Hidden when there's
/// no Soniox key to speak with.
struct SpeakAloudToggle: View {
    let store: ConversationStore
    var settings: AppSettings = .shared

    var body: some View {
        if store.canSpeakTranslations {
            Toggle(
                "Speak Translations",
                systemImage: "speaker.wave.2",
                isOn: Binding(get: { settings.speaksTranslations }, set: { store.setSpeaksTranslations($0) })
            )
        }
    }
}

/// Switches speech-to-speech mode: translations into the second language
/// are read aloud. Hidden when there's no Soniox key to speak with.
struct SpeakAloudButton: View {
    let store: ConversationStore
    var settings: AppSettings = .shared

    var body: some View {
        if store.canSpeakTranslations {
            let on = settings.speaksTranslations
            GlassIconButton(
                systemImage: on ? "speaker.wave.2.fill" : "speaker.slash",
                label: on ? "Stop speaking translations aloud" : "Speak translations aloud",
                isOn: on
            ) {
                store.setSpeaksTranslations(!on)
            }
            .sensoryFeedback(.selection, trigger: on)
        }
    }
}

/// An optional text field for typing a line to translate, for when speaking
/// isn't practical. Opening it offers to download on-device languages, which
/// typed text uses when no translation key is set. Its photo button reads the
/// text in a photo, such as a sign or a menu, and translates it the same way.
struct TypeToTranslateBar: View {
    let store: ConversationStore
    let languages: LanguagePair
    /// The typist's language, for text that could be either.
    let language: Language
    var script: ChineseScript = AppSettings.shared.chineseScript
    /// A turn whose transcript is being corrected; sending replaces it.
    @Binding var editing: Utterance?
    /// Owned by the screen, so it can drop the keyboard before removing the bar.
    var focused: FocusState<Bool>.Binding
    var onClose: () -> Void

    init(
        store: ConversationStore, languages: LanguagePair, language: Language,
        editing: Binding<Utterance?> = .constant(nil), focused: FocusState<Bool>.Binding,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.languages = languages
        self.language = language
        _editing = editing
        self.focused = focused
        self.onClose = onClose
    }

    @State private var text = ""
    @State private var download: TranslationSession.Configuration?
    @State private var photo: PhotosPickerItem?
    @State private var choosesPhoto = false
    @State private var takesPhoto = false
    @State private var readsPhoto = false

    var body: some View {
        HStack(spacing: 8) {
            if editing != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .accessibilityHidden(true)
            } else {
                photoButton
            }
            TextField(editing == nil ? "Type to translate" : "Fix what was heard", text: $text)
                // Corrections are often names, which autocorrect would undo.
                .autocorrectionDisabled(editing != nil)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 10)
            Button(action: send) {
                Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.4 : 1)
            .accessibilityLabel(editing == nil ? "Translate" : "Save and translate again")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(editing == nil ? "Close text input" : "Cancel editing")
            .padding(.trailing, 6)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onChange(of: editing?.id, initial: true) {
            guard let editing else { return }
            text = editing.trimmedSource
            focused.wrappedValue = true
        }
        .onAppear {
            focused.wrappedValue = true
            guard store.translatesTypedTextOnDevice else { return }
            download = TranslationSession.Configuration(
                source: AppleTranslator.language(languages.first, script: script),
                target: AppleTranslator.language(languages.second, script: script)
            )
        }
        .translationTask(download) { session in
            // Offers the download if the pair isn't on the device yet. The
            // session is only used here, inside the task SwiftUI gives it to.
            nonisolated(unsafe) let session = session
            try? await session.prepareTranslation()
        }
        .photosPicker(isPresented: $choosesPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await translatePhoto { try await item.loadTransferable(type: Data.self) } }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $takesPhoto) {
            CameraPicker { image in
                takesPhoto = false
                guard let image = image?.jpegData(compressionQuality: 0.9) else { return }
                Task { await translatePhoto { image } }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// Takes or chooses a photo to translate. Without a camera, as on the
    /// Mac, it goes straight to the photo picker.
    private var photoButton: some View {
        Group {
            if readsPhoto {
                ProgressView().controlSize(.small)
            } else if CameraPicker.isAvailable {
                Menu {
                    Button("Take Photo", systemImage: "camera") { takesPhoto = true }
                    Button("Choose Photo", systemImage: "photo.on.rectangle") { choosesPhoto = true }
                } label: {
                    photoIcon
                }
                .menuIndicator(.hidden)
            } else {
                Button { choosesPhoto = true } label: { photoIcon }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .padding(.leading, 6)
        .accessibilityLabel(readsPhoto ? "Reading photo" : "Translate a photo")
    }

    private var photoIcon: some View {
        Image(systemName: "camera")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .contentShape(.circle)
    }

    /// Reads the photo's text on the device and adds it as a typed turn.
    private func translatePhoto(_ load: () async throws -> Data?) async {
        readsPhoto = true
        defer { readsPhoto = false }
        do {
            guard let image = try await load() else { return }
            let text = try await TextRecognizer.text(in: image, languages: languages)
            guard !text.isEmpty else {
                store.alert = "Lively couldn't find any text in that photo."
                return
            }
            withAnimation(.snappy) { store.submitTyped(text, language: language) }
        } catch {
            store.alert = "Lively couldn't read that photo."
        }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard !isEmpty else { return }
        if let editing {
            store.edit(editing, to: text)
            self.editing = nil
        } else {
            withAnimation(.snappy) { store.submitTyped(text, language: language) }
        }
        text = ""
        focused.wrappedValue = true
    }

    /// Cancels an edit, or closes the bar.
    private func close() {
        guard editing != nil else { return onClose() }
        editing = nil
        text = ""
    }
}

#if os(iOS)
/// The system camera, for photographing text to translate.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// Called with the photo, or nil when the camera is cancelled.
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
    }
}
#else
/// The Mac has no camera to take photos with here; it chooses photos instead.
enum CameraPicker {
    static let isAvailable = false
}
#endif
