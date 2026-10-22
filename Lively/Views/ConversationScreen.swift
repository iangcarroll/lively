import SwiftUI

struct ConversationScreen: View {
    @State var store: ConversationStore
    @Bindable var settings: AppSettings = .shared

    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var showPro = false
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var didStartDemoAutomatically = false
    /// On phones, face-to-face is the main layout; the transcript is an alternative.
    @AppStorage("phoneShowsTranscript") private var phoneShowsTranscript = false
    @AppStorage("nearLanguage") private var nearLanguage: Language = .english
    @Environment(\.scenePhase) private var scenePhase

    /// Unfolded iPhone Duo, landscape phones, iPad and Mac get side-by-side columns.
    private static let wideBreakpoint: CGFloat = 640

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideBreakpoint
            ZStack {
                Color(.canvas).ignoresSafeArea()

                if !wide && !phoneShowsTranscript {
                    FaceToFaceScreen(
                        store: store,
                        languages: settings.languages,
                        nearLanguage: near,
                        onShowTranscript: { withAnimation(.snappy) { phoneShowsTranscript = true } },
                        onShowSettings: { showSettings = true }
                    )
                    .transition(.opacity)
                } else {
                    transcript(wide: wide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaBar(edge: .top) { topBar(wide: wide) }
                        .safeAreaBar(edge: .bottom) { controls }
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: showSettings) { _, shown in
            if !shown { store.settingsDidClose() }
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
            }
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

    private func topBar(wide: Bool) -> some View {
        HStack(spacing: 10) {
            StatusPill(status: store.status, isListening: store.isListening)
            Spacer()
            if !wide {
                GlassIconButton(systemImage: "rectangle.split.1x2", label: "Face-to-face mode") {
                    withAnimation(.snappy) { phoneShowsTranscript = false }
                }
            }
            GlassIconButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func transcript(wide: Bool) -> some View {
        if store.visibleUtterances.isEmpty {
            EmptyConversation(isListening: store.isListening)
        } else if wide {
            ParallelTranscript(store: store)
        } else {
            ChatTranscript(store: store)
        }
    }

    private var controls: some View {
        HStack {
            GlassIconButton(systemImage: "trash", label: "Clear conversation") {
                withAnimation(.snappy) { store.clear() }
            }
            .disabled(store.utterances.isEmpty)
            .opacity(store.utterances.isEmpty ? 0.4 : 1)
            Spacer()
            MicButton(isListening: store.isListening, level: store.level) {
                store.toggleListening()
            }
            Spacer()
            // Balances the left button so the mic stays centered.
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
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
