import SwiftUI
import Translation

struct ConversationScreen: View {
    @State var store: ConversationStore
    @Bindable var settings: AppSettings = .shared

    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var showPro = false
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var didStartDemoAutomatically = false
    @State private var showsTextInput = false
    @FocusState private var textInputFocused: Bool
    /// The turn being corrected in the text bar.
    @State private var editing: Utterance?
    /// The bar opened for an edit, so it closes when the edit ends.
    @State private var textInputOpenedForEdit = false
    /// On phones, face-to-face is the main layout; the transcript is an alternative.
    @AppStorage("phoneShowsTranscript") private var phoneShowsTranscript = false
    @AppStorage("nearLanguage") private var nearLanguage: Language = .english
    @Environment(\.scenePhase) private var scenePhase

    /// Unfolded iPhone Duo, landscape phones, iPad and Mac get side-by-side columns.
    private static let wideBreakpoint: CGFloat = 640

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideBreakpoint
            let column = StatusColumn(size: geometry.size, insets: geometry.safeAreaInsets)
            ZStack {
                Color(.canvas).ignoresSafeArea()

                if !wide && !phoneShowsTranscript {
                    FaceToFaceScreen(
                        store: store,
                        languages: settings.languages,
                        nearLanguage: near,
                        showsTextInput: showsTextInput,
                        textInputFocused: $textInputFocused,
                        onSetTextInput: setTextInput,
                        editing: $editing,
                        onEdit: startEditing,
                        onShowTranscript: { withAnimation(.snappy) { phoneShowsTranscript = true } },
                        onShowSettings: { showSettings = true },
                        statusColumn: column
                    )
                    // Below its status icons, the iPhone Duo's column is free.
                    .ignoresSafeArea(edges: column?.edges ?? [])
                    .transition(.opacity)
                } else {
                    // A stable container, so the bars aren't rebuilt when the
                    // first turn replaces the empty state; that would drop a
                    // press on the mic mid-hold.
                    // It spans the iPhone Duo's column, so the bottom bar's
                    // buttons in it take taps; everything else keeps clear of it.
                    ZStack { transcript(wide: wide).padding(column?.edges ?? [], column?.width ?? 0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaBar(edge: .top) {
                            topBar(wide: wide, column: column)
                                .padding(column?.edges ?? [], column?.width ?? 0)
                        }
                        .safeAreaBar(edge: .bottom) { controls(column: column) }
                        .ignoresSafeArea(edges: column?.edges ?? [])
                        .transition(.opacity)
                }
            }
            .overlayPreferenceValue(KeyboardButtonBounds.self) { keyboard in
                // In the status column, the other buttons stack above the
                // keyboard button, clear of however far its status icons
                // reach, which iOS doesn't report. They're drawn here rather
                // than on the bottom bar so they take taps outside its bounds.
                // While typing, the software keyboard lifts the bar too near
                // the status icons, so they step aside.
                if column != nil, !textInputFocused, let keyboard {
                    GeometryReader { proxy in
                        let bounds = proxy[keyboard]
                        VStack(spacing: 10) { trailingButtons(wide: wide) }
                            .frame(width: bounds.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .offset(x: bounds.minX, y: bounds.minY - 10 - proxy.size.height)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isUsingOnDevice || settings.provider.id == SpeechProvider.onDevice.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On-device · Who's speaking?").font(.caption.weight(.semibold))
                    Picker("Who's speaking?", selection: $settings.offlineSpokenLanguage) {
                        ForEach(settings.languages.all) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.canvas))
            }
        }
        .onChange(of: editing == nil) { _, done in
            guard done, textInputOpenedForEdit else { return }
            textInputOpenedForEdit = false
            setTextInput(false)
        }
        .onChange(of: showsTextInput) { _, shown in
            if !shown { editing = nil }
        }
        .onChange(of: showSettings) { _, shown in
            if !shown { store.settingsDidClose() }
        }
        .onChange(of: settings.languages) { _, _ in
            store.speechRoutingDidChange()
        }
        .onChange(of: settings.speechListenerLanguage) { _, _ in
            store.speechRoutingDidChange()
        }
        .onChange(of: settings.offlineSpokenLanguage) { _, _ in
            if store.isUsingOnDevice || settings.provider.id == SpeechProvider.onDevice.id { store.offlineSpeakerDidChange() }
        }
        .onChange(of: settings.providerID) { _, _ in
            store.offlineSpeakerDidChange()
        }
        .onChange(of: settings.chineseScript) { _, _ in
            store.offlineSpeakerDidChange()
        }
        .onChange(of: settings.speaksTranslations) { _, enabled in
            store.setSpeaksTranslations(enabled)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, onClear: { store.clear() }, onShowWelcome: { showOnboarding = true })
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) { onboarding }
        #else
        .sheet(isPresented: $showOnboarding) { onboarding.frame(width: 520, height: 760) }
        #endif
        .sheet(isPresented: $showPro) {
            NavigationStack {
                ProView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showPro = false } }
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 640)
            #endif
        }
        .alert("Lively", isPresented: alertBinding) {
            if !settings.hasCredentials { Button("Open Settings") { showSettings = true } }
            if Pro.shared.freeLimitReached && !Pro.shared.isPro { Button("Get Lively Pro") { showPro = true } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.didBecomeActive() }
            #if os(iOS)
            // iOS takes the mic away in the background anyway; stop cleanly.
            if phase == .background { store.didEnterBackground() }
            #endif
        }
        .onOpenURL(perform: open)
        .onAppear {
            if forcesOnboarding {
                showOnboarding = true
                return
            }
            if isDemo {
                if isDemoAutoPlay && !didStartDemoAutomatically {
                    didStartDemoAutomatically = true
                    store.toggleListening()
                }
                return
            }
            if !onboardingDone {
                showOnboarding = true
            } else if !settings.hasCredentials {
                showSettings = true
            } else {
                store.prewarm()
            }
        }
    }

    /// Links from the home and lock screen widgets: `lively://listen` starts
    /// listening, `lively://type` opens the text bar. Ignored until the
    /// welcome tour is done, since it picks the languages.
    private func open(_ url: URL) {
        guard url.scheme == "lively", onboardingDone || isDemo, !showOnboarding else { return }
        switch url.host() {
        case "listen": store.startListening()
        case "type": setTextInput(true)
        default: break
        }
    }

    /// The near side's language, kept within the current pair.
    private var near: Binding<Language> {
        Binding(
            get: { settings.languages.contains(nearLanguage) ? nearLanguage : settings.languages.first },
            set: { nearLanguage = $0 }
        )
    }

    private var onboarding: some View {
        OnboardingView(settings: settings) {
            onboardingDone = true
            nearLanguage = settings.languages.first
            showOnboarding = false
            if !settings.hasCredentials {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    showSettings = true
                }
            }
        }
    }

    /// Launch with `-LivelyOnboarding YES` to see the welcome tour every time.
    private var forcesOnboarding: Bool { UserDefaults.standard.bool(forKey: "LivelyOnboarding") }

    private var isDemo: Bool { UserDefaults.standard.bool(forKey: "LivelyDemo") }
    private var isDemoAutoPlay: Bool {
        UserDefaults.standard.bool(forKey: "LivelyDemoAutoPlay")
    }

    private func topBar(wide: Bool, column: StatusColumn?) -> some View {
        HStack(spacing: 10) {
            StatusPill(status: store.status, isListening: store.isListening, onDevice: store.isUsingOnDevice)
            Spacer()
            if column == nil { trailingButtons(wide: wide) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func trailingButtons(wide: Bool) -> some View {
        // Turned on from the menu in face-to-face or Settings; shown while
        // on, so it can be stopped from here.
        if settings.speaksTranslations { SpeakAloudButton(store: store, settings: settings) }
        if !wide {
            GlassIconButton(systemImage: "rectangle.split.1x2", label: "Face-to-face mode") {
                withAnimation(.snappy) { phoneShowsTranscript = false }
            }
        }
        GlassIconButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
    }

    @ViewBuilder
    private func transcript(wide: Bool) -> some View {
        if store.visibleUtterances.isEmpty {
            EmptyConversation(isListening: store.isListening, isConnecting: store.isConnecting)
        } else if wide {
            ParallelTranscript(store: store, onEdit: startEditing)
        } else {
            ChatTranscript(store: store, onEdit: startEditing)
        }
    }

    private func controls(column: StatusColumn?) -> some View {
        VStack(spacing: 8) {
            if showsTextInput {
                TypeToTranslateBar(
                    store: store, languages: settings.languages, language: settings.languages.first,
                    editing: $editing, focused: $textInputFocused
                ) { setTextInput(false) }
                .padding(.horizontal, 16)
                .padding(column?.edges ?? [], column?.width ?? 0)
                .transition(.opacity)
            }
            if !store.visibleUtterances.isEmpty {
                TranscriptListeningStatus(
                    status: store.status,
                    isListening: store.isListening,
                    languages: settings.languages
                )
                .padding(.horizontal, 16)
                .padding(column?.edges ?? [], column?.width ?? 0)
            }
            // The status column is free this far down, so the keyboard button
            // sits in it, under the status icons, with the column's other
            // buttons stacked above it.
            controlRow(column: column)
        }
    }

    private func controlRow(column: StatusColumn?) -> some View {
        ZStack(alignment: .top) {
            HStack {
                GlassIconButton(systemImage: "trash", label: "Clear conversation") {
                    withAnimation(.snappy) { store.clear() }
                }
                .disabled(store.utterances.isEmpty)
                .opacity(store.utterances.isEmpty ? 0.4 : 1)
                Spacer()
                GlassIconButton(systemImage: showsTextInput ? "keyboard.chevron.compact.down" : "keyboard", label: "Type to translate") {
                    setTextInput(!showsTextInput)
                }
                .anchorPreference(key: KeyboardButtonBounds.self, value: .bounds) { $0 }
            }
            .frame(height: 76)
            .padding(.horizontal, 24)
            .padding(column?.edges ?? [], (column?.inset(centering: GlassIconButton.size) ?? 24) - 24)
            // The mic centers on the transcript above it, beside the column.
            VStack(spacing: 4) {
                MicButton(isListening: store.isListening, level: store.level, isHearing: store.isHearing) {
                    store.toggleListening()
                } onHoldStart: {
                    store.startListening()
                } onHoldEnd: {
                    store.stopListening()
                }
                Text(store.isListening ? "Stop" : "Start")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(width: 112)
            .padding(column?.edges ?? [], column?.width ?? 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Opens the text bar on a turn's transcript to correct it.
    private func startEditing(_ utterance: Utterance) {
        textInputOpenedForEdit = !showsTextInput
        editing = utterance
        setTextInput(true)
    }

    /// Shows or hides the text bar. Hiding drops the keyboard first, while
    /// the field is still there, so the controls ride down with it; removing
    /// a focused field makes the keyboard vanish and the layout jump.
    private func setTextInput(_ shown: Bool) {
        guard shown != showsTextInput else { return }
        guard !shown else {
            withAnimation(.snappy) { showsTextInput = true }
            return
        }
        textInputFocused = false
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy) { showsTextInput = false }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { store.alert != nil }, set: {
            if !$0 {
                store.alert = nil
                Pro.shared.freeLimitReached = false
            }
        })
    }
}

/// Where the bottom bar's keyboard button is, for the iPhone Duo's column
/// buttons that stack above it.
private struct KeyboardButtonBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
