import StoreKit
import SwiftUI
import Translation

struct ConversationScreen: View {
    @State var store: ConversationStore
    @Bindable var settings: AppSettings = .shared

    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var showLanguages = false
    /// Conversations long enough to have been worth having, for `ReviewPrompt`.
    @AppStorage("goodConversations") private var goodConversations = 0
    @AppStorage("reviewAsked") private var reviewAsked = false
    /// This conversation has been counted; cleared with the conversation.
    @State private var countedConversation = false
    @Environment(\.requestReview) private var requestReview
    @AppStorage("onboardingDone") private var onboardingDone = false
    /// The card offering "Set from location", shown once on an open after the welcome tour.
    @State private var showLocationOffer = false
    @AppStorage("locationOfferDone") private var locationOfferDone = false
    #if DEBUG
    @State private var didStartDemoAutomatically = false
    #endif
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

    private var conversationCanvas: some View {
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
                        onShowLanguages: { showLanguages = true },
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
            if store.asksWhoIsSpeaking {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On-device · Who's speaking?").font(.caption.weight(.semibold))
                    Picker("Who's speaking?", selection: $settings.offlineSpokenLanguage) {
                        ForEach(settings.languages.all) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    if !store.isOnline, settings.speaksTranslations, settings.speechSource == .original {
                        Text("Original voice needs internet; translations stay visible.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.speaksTranslations, settings.speechSource == .downloaded, !NeuralVoicePacks.shared.isReady {
                        Text(NeuralVoicePacks.shared.status == .checking
                             ? "Checking downloaded voices…"
                             : "Download voices in Settings → Offline Voice Library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.canvas))
            }
        }
    }

    private var observedConversation: some View {
        conversationCanvas
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
        .onChange(of: settings.speechSource) { _, _ in store.speechRoutingDidChange() }
        .onChange(of: NeuralVoicePacks.shared.selectionRevision) { _, _ in store.speechRoutingDidChange() }
        .onChange(of: NeuralVoicePacks.shared.installedDirectory) { previous, current in
            // First verification can publish files that a new speaker is
            // already waiting for. Only replacing or removing an existing
            // installation invalidates that speaker.
            if previous != nil { store.speechRoutingDidChange() }
            if current == nil { Task { await NeuralSpeaker.releaseCachedModel() } }
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
    }

    var body: some View {
        observedConversation
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, onClear: { store.clear() }, onShowWelcome: { showOnboarding = true },
                         onPauseForVoicePreview: {
                             store.stopListening()
                             store.speechRoutingDidChange()
                         })
        }
        .sheet(isPresented: $showLanguages, onDismiss: { store.settingsDidClose() }) {
            LanguagesSheet(settings: settings)
        }
        .onChange(of: store.isListening) { was, now in
            if was && !now { conversationPaused() }
        }
        .onChange(of: hitFreeLimit) { was, now in
            // Subscribing ends the limit without closing the sheet by hand;
            // its message mustn't come back as an alert.
            if was && !now {
                store.alert = nil
                Pro.shared.freeLimitReached = false
            }
        }
        .onChange(of: store.utterances.isEmpty) { _, empty in
            if empty { countedConversation = false }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) { onboarding }
        #else
        .sheet(isPresented: $showOnboarding) { onboarding.frame(width: 520, height: 760) }
        #endif
        // A used-up free day opens Lively Pro itself, which also offers the
        // free way on, rather than an alert that only names it.
        .sheet(isPresented: limitBinding) {
            NavigationStack {
                ProView(limitReached: true).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { limitBinding.wrappedValue = false } }
                }
            }
            // Signed in from here: back to the conversation, where Start now works.
            .onChange(of: Account.shared?.isSignedIn) { _, signedIn in
                if signedIn == true { limitBinding.wrappedValue = false }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 640)
            #endif
        }
        .alert("Lively", isPresented: alertBinding) {
            if !settings.hasCredentials { Button("Open Settings") { showSettings = true } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        .overlay {
            if showLocationOffer {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { closeLocationOffer(changed: false) }
                    LocationOfferCard(onDone: closeLocationOffer)
                        .frame(maxWidth: 380)
                        .padding(24)
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: showLocationOffer)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.didBecomeActive()
                followLocation()
            }
            #if os(iOS)
            // iOS takes the mic away in the background anyway; stop cleanly.
            if phase == .background { store.didEnterBackground() }
            if phase == .background { Task { await NeuralSpeaker.releaseCachedModel() } }
            #endif
        }
        .onOpenURL(perform: open)
        .onAppear {
            Task { await NeuralVoicePacks.shared.refresh() }
            if forcesOnboarding {
                showOnboarding = true
                return
            }
            #if DEBUG
            if showsDemoLimit {
                Pro.shared.freeLimitReached = true
                store.alert = "Today's free translation time is used up."
            }
            if isDemo {
                if isDemoAutoPlay && !didStartDemoAutomatically {
                    didStartDemoAutomatically = true
                    store.toggleListening()
                }
                return
            }
            #endif
            if !onboardingDone {
                showOnboarding = true
            } else if !settings.hasCredentials {
                showSettings = true
            } else {
                store.prewarm()
            }
            // Not on the launch that shows the welcome tour, which has its own button.
            if onboardingDone, !locationOfferDone, !settings.usesLocationLanguages { showLocationOffer = true }
            // scenePhase is already active at launch, so onChange doesn't run.
            followLocation()
        }
    }

    /// With "Set from location" on, sets the pair on arriving in another
    /// country. Not over a conversation: changing the pair clears it.
    private func followLocation() {
        guard settings.usesLocationLanguages, !isDemo else { return }
        Task {
            let idle = store.utterances.isEmpty && !store.isListening
            if await LocationLanguages.shared.update(canChange: idle) { store.settingsDidClose() }
        }
    }

    /// Either answer on the card counts; it isn't shown again.
    private func closeLocationOffer(changed: Bool) {
        locationOfferDone = true
        showLocationOffer = false
        if changed { store.settingsDidClose() }
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
    private var forcesOnboarding: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "LivelyOnboarding")
        #else
        false
        #endif
    }

    private var isDemo: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "LivelyDemo")
        #else
        false
        #endif
    }
    #if DEBUG
    private var isDemoAutoPlay: Bool {
        UserDefaults.standard.bool(forKey: "LivelyDemoAutoPlay")
    }

    /// Launch with `-LivelyLimit YES` to see a used-up free day without the broker.
    private var showsDemoLimit: Bool {
        UserDefaults.standard.bool(forKey: "LivelyLimit")
    }
    #endif

    private func topBar(wide: Bool, column: StatusColumn?) -> some View {
        // The pair names both languages where there's room, and is a plain
        // button where there isn't.
        ViewThatFits(in: .horizontal) {
            topBarRow(wide: wide, column: column) {
                LanguagePairButton(languages: settings.languages) { showLanguages = true }
            }
            topBarRow(wide: wide, column: column) {
                GlassIconButton(systemImage: "globe", label: "Change languages") { showLanguages = true }
            }
        }
    }

    private func topBarRow(wide: Bool, column: StatusColumn?, @ViewBuilder languages: () -> some View) -> some View {
        HStack(spacing: 10) {
            StatusPill(status: store.status, isListening: store.isListening, onDevice: store.isUsingOnDevice)
                .fixedSize()
            Spacer(minLength: 0)
            languages()
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

    /// Listening stopped. After a couple of conversations long enough to
    /// have been useful, asks once for an App Store review; iOS decides
    /// whether to show it. Android asks Google Play the same way.
    private func conversationPaused() {
        guard !isDemo, !countedConversation else { return }
        let turns = store.utterances.count(where: \.isFinal)
        guard turns >= ReviewPrompt.minTurns else { return }
        countedConversation = true
        goodConversations += 1
        guard ReviewPrompt.shouldAsk(turns: turns, goodConversations: goodConversations, alreadyAsked: reviewAsked) else { return }
        Task {
            // Not on top of the last line being read.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !store.isListening else { return }
            reviewAsked = true
            requestReview()
        }
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

    /// Today's free time ran out and there's no Pro: the alert's message is
    /// the limit, which the Lively Pro sheet shows instead.
    private var hitFreeLimit: Bool {
        store.alert != nil && Pro.shared.freeLimitReached && !Pro.shared.isPro
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { store.alert != nil && !hitFreeLimit }, set: {
            if !$0 {
                store.alert = nil
                Pro.shared.freeLimitReached = false
            }
        })
    }

    private var limitBinding: Binding<Bool> {
        Binding(get: { hitFreeLimit }, set: {
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

/// Asks whether to turn on "Set from location". Saying yes shows the system's
/// location prompt; if the pair can't be set, the card says why before closing.
struct LocationOfferCard: View {
    /// Called with true when the languages were set.
    var onDone: (_ changed: Bool) -> Void
    @State private var asked = false
    private var location: LocationLanguages { .shared }

    private var isWorking: Bool { location.isEnabling || location.status == .locating }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.gradient, in: .circle)
            Text("Set languages from your location?")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(asked ? location.status.message ?? "Finding where you are…"
                 : "Lively can choose your language and the local one for the country you're in, "
                 + "and again when you travel. You can change this in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !asked {
                VStack(spacing: 4) {
                    Button(action: enable) {
                        Text("Use My Location")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressableCapsule())
                    Button("Not Now") { onDone(false) }
                        .font(.body.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .padding(.top, 6)
            } else if isWorking {
                ProgressView().frame(minHeight: 44)
            } else {
                Button("OK") { onDone(false) }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .padding(24)
        .background(Color(.card), in: .rect(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func enable() {
        asked = true
        Task {
            await location.enable()
            if case .applied = location.status { onDone(true) }
        }
    }
}
