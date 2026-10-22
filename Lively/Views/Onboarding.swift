import SwiftUI

/// First launch: a short, mostly visual tour. It shows Lively working
/// instead of describing it, picks the two languages, and offers sign-in.
struct OnboardingView: View {
    @Bindable var settings: AppSettings
    var onFinish: () -> Void

    @State private var step: Step = .welcome
    /// Which way the last step change went, for the slide direction.
    @State private var forward = true
    @Environment(\.colorScheme) private var colorScheme

    enum Step: Int, CaseIterable {
        case welcome, table, languages, account
    }

    /// Sign-in is offered only when the build has an account service.
    private var steps: [Step] {
        Account.shared == nil ? [.welcome, .table, .languages] : Step.allCases
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                page
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        // The sign-in field sits high enough to clear the keyboard; the
        // page dots and Not Now stay put behind it.
        .ignoresSafeArea(.keyboard)
        .contentShape(.rect)
        .gesture(swipe)
        .animation(.smooth(duration: 0.45), value: step)
        #if os(iOS)
        // Dark status bar text would clash with the gradient.
        .statusBarHidden(step == .welcome)
        #endif
    }

    @ViewBuilder
    private var background: some View {
        if step == .welcome {
            LivelyGradient().ignoresSafeArea().transition(.opacity)
        } else {
            Color(.canvas).ignoresSafeArea().transition(.opacity)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage(languageCount: SpeechProvider.all.map(\.languages.count).max() ?? 0).environment(\.colorScheme, .dark)
        case .table: TablePage()
        case .languages: LanguagesPage(settings: settings)
        case .account: if let account = Account.shared { AccountPage(account: account, onSignedIn: onFinish) }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            PageDots(count: steps.count, current: steps.firstIndex(of: step) ?? 0, light: step == .welcome)
                .environment(\.colorScheme, step == .welcome ? .dark : colorScheme)
            if step == .account {
                Button("Not Now", action: onFinish)
                    .font(.body.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(.rect)
            } else {
                Button(action: advance) {
                    Text(primaryTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(step == .welcome ? Self.welcomeInk : .white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressableCapsule(fill: step == .welcome ? .white : .accentColor))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    /// The light-mode first-language ink; the welcome page is always dark.
    private static let welcomeInk = Color(red: 0.239, green: 0.31, blue: 0.839)

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .languages where !steps.contains(.account): "Start Talking"
        default: "Continue"
        }
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            onFinish()
            return
        }
        forward = true
        step = steps[index + 1]
    }

    private func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        forward = false
        step = steps[index - 1]
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height) * 1.5 else { return }
                if drag.translation.width < -60, step != .account { advance() }
                if drag.translation.width > 60 { goBack() }
            }
    }
}

// MARK: - Pages

/// The page layout every step shares: a picture, then a title and a line or two.
private struct OnboardingPage<Art: View>: View {
    let title: String
    let message: String
    var light = false
    @ViewBuilder var art: Art
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            art
                // iPad and the unfolded Duo have room for a bigger picture.
                .scaleEffect(sizeClass == .regular ? 1.3 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(light ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(light ? .white : .primary)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
    }
}

private struct WelcomePage: View {
    let languageCount: Int

    var body: some View {
        OnboardingPage(
            title: "Lively",
            message: "Talk with anyone, face to face. Lively translates both of you as you speak, in \(languageCount) languages.",
            light: true
        ) {
            GreetingBubbles()
        }
    }
}

private struct TablePage: View {
    var body: some View {
        OnboardingPage(
            title: "Lay it flat between you",
            message: "Just talk. Lively hears who's speaking, and each of you reads your own half, in your own language."
        ) {
            TableDemo()
        }
    }
}

private struct LanguagesPage: View {
    @Bindable var settings: AppSettings
    @State private var choosing: LanguageSide?

    var body: some View {
        OnboardingPage(
            title: "Pick your languages",
            message: "Lively listens for both and translates each into the other. You can change them any time."
        ) {
            VStack(spacing: -14) {
                LanguageCard(caption: "You speak", language: settings.languages.first, ink: Color(.firstLanguageInk)) {
                    choosing = .first
                }
                swapButton.zIndex(1)
                LanguageCard(caption: "They speak", language: settings.languages.second, ink: Color(.secondLanguageInk)) {
                    choosing = .second
                }
            }
            .padding(.horizontal, 24)
            .overlay(alignment: .bottom) {
                if settings.languages.contains(.chinese) {
                    Picker("Chinese script", selection: $settings.chineseScript) {
                        ForEach(ChineseScript.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .offset(y: 52)
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: settings.languages)
        }
        .sheet(item: $choosing) { side in
            NavigationStack {
                LanguageList(settings: settings, side: side, title: side == .first ? "You Speak" : "They Speak")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", systemImage: "xmark") { choosing = nil }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var swapButton: some View {
        Button {
            settings.languages = LanguagePair(first: settings.languages.second, second: settings.languages.first)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .sensoryFeedback(.selection, trigger: settings.languages)
        .accessibilityLabel("Swap languages")
    }
}

/// One side of the pair: the language's own name, large, in its ink.
private struct LanguageCard: View {
    let caption: String
    let language: Language
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(language.nativeName)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(ink)
                        .contentTransition(.opacity)
                    if language.englishName != language.nativeName {
                        Text(language.englishName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                shape.fill(Color(.card))
                shape.fill(ink.opacity(0.06))
                shape.strokeBorder(ink.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(caption): \(language.englishName)")
        .accessibilityHint("Choose a language")
    }
}

private struct AccountPage: View {
    let account: Account
    var onSignedIn: () -> Void

    var body: some View {
        ScrollView {
            AccountContent(account: account)
                .padding(.top, 40)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { onSignedIn() }
        }
    }
}

// MARK: - Pieces

enum LanguageSide: String, Identifiable {
    case first, second
    var id: String { rawValue }
    var keyPath: WritableKeyPath<LanguagePair, Language> { self == .first ? \.first : \.second }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    var light = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(light ? Color.white : Color.primary)
                    .opacity(index == current ? 0.9 : 0.22)
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// A full-width capsule button that shrinks a little under the finger.
struct PressableCapsule: ButtonStyle {
    var fill: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill, in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// The app icon's blue-to-red wash, drifting slowly.
struct LivelyGradient: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate)
            let drift = SIMD2<Float>(sin(t * 0.35) * 0.18, cos(t * 0.27) * 0.14)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5] + drift, [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Color(red: 0.25, green: 0.33, blue: 0.86), Color(red: 0.33, green: 0.31, blue: 0.80), Color(red: 0.45, green: 0.30, blue: 0.70),
                    Color(red: 0.31, green: 0.30, blue: 0.80), Color(red: 0.47, green: 0.29, blue: 0.66), Color(red: 0.66, green: 0.29, blue: 0.48),
                    Color(red: 0.42, green: 0.29, blue: 0.68), Color(red: 0.70, green: 0.29, blue: 0.40), Color(red: 0.86, green: 0.30, blue: 0.20),
                ]
            )
        }
    }
}

/// The app icon, alive: two speech bubbles saying hello to each other in a
/// new pair of languages every couple of seconds.
private struct GreetingBubbles: View {
    private static let greetings: [(String, String)] = [
        ("Hello", "你好"), ("Hola", "Bonjour"), ("Ciao", "こんにちは"), ("Olá", "안녕하세요"),
        ("Hallo", "Привет"), ("Merhaba", "नमस्ते"), ("Hej", "مرحبا"), ("Xin chào", "Γεια σου"),
    ]

    @State private var index = 0
    /// The answer lags the greeting a moment, like a translation catching up.
    @State private var answerIndex = 0
    @State private var appeared = false

    var body: some View {
        ZStack {
            GreetingBubble(text: Self.greetings[index].0, ink: Color(.firstLanguageInk), tailLeading: true)
                .offset(x: -44, y: -46)
                .scaleEffect(appeared ? 1 : 0.6, anchor: .bottomLeading)
                .opacity(appeared ? 1 : 0)
            GreetingBubble(text: Self.greetings[answerIndex].1, ink: Color(.secondLanguageInk), tailLeading: false)
                .offset(x: 44, y: 46)
                .scaleEffect(appeared ? 1 : 0.6, anchor: .topTrailing)
                .opacity(appeared ? 1 : 0)
        }
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
        .task {
            withAnimation(.spring(duration: 0.7, bounce: 0.35).delay(0.15)) { appeared = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.smooth(duration: 0.5)) { index = (index + 1) % Self.greetings.count }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.smooth(duration: 0.5)) { answerIndex = index }
            }
        }
    }
}

private struct GreetingBubble: View {
    let text: String
    let ink: Color
    let tailLeading: Bool

    var body: some View {
        // The ZStack keeps the swap to the word; the bubble stays put.
        ZStack {
            Text(text)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 18)
                .id(text)
                .transition(.blurReplace)
        }
        .frame(width: 196, height: 96)
        .background(.white, in: BubbleShape(tailLeading: tailLeading))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }
}

/// A rounded speech bubble with a small tail at a bottom corner, like the icon's.
nonisolated struct BubbleShape: Shape {
    var tailLeading: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 30, style: .continuous)
        let x = tailLeading ? rect.minX + 30 : rect.maxX - 30
        let direction: CGFloat = tailLeading ? -1 : 1
        var tail = Path()
        tail.move(to: CGPoint(x: x - 14 * direction, y: rect.maxY - 2))
        tail.addQuadCurve(
            to: CGPoint(x: x + 16 * direction, y: rect.maxY + 18),
            control: CGPoint(x: x + 6 * direction, y: rect.maxY + 10)
        )
        tail.addQuadCurve(
            to: CGPoint(x: x + 12 * direction, y: rect.maxY - 2),
            control: CGPoint(x: x + 10 * direction, y: rect.maxY + 6)
        )
        tail.closeSubpath()
        return path.union(tail)
    }
}

/// A little phone that lies down on the table and plays a conversation:
/// each half shows its reader's language, the far half upside down.
private struct TableDemo: View {
    private static let script = Array(DemoConversation.script.prefix(3))

    @State private var tilted = false
    /// Lines started so far.
    @State private var lineCount = 0
    /// Characters of the newest line spoken so far.
    @State private var spokenLength = 0
    /// The newest line's translation is showing.
    @State private var translated = false
    @State private var listening = false
    @Environment(\.colorScheme) private var colorScheme

    private var bezel: Color { Color(white: colorScheme == .dark ? 0.24 : 0.12) }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.black.opacity(tilted ? 0.12 : 0))
                .frame(width: 240, height: 54)
                .blur(radius: 18)
                .offset(y: 124)
            phone
                .rotation3DEffect(.degrees(tilted ? 44 : 0), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.55)
                .offset(y: tilted ? 12 : 0)
        }
        .frame(height: 360)
        .accessibilityElement()
        .accessibilityLabel("A phone lying flat between two people. Each half shows the conversation in one person's language.")
        .task { await play() }
    }

    private var phone: some View {
        VStack(spacing: 0) {
            half(english: false)
                .rotationEffect(.degrees(180))
            HStack {
                Capsule().fill(.quaternary).frame(height: 1)
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 2)
                        .scaleEffect(listening ? 1.45 : 1)
                        .opacity(listening ? 0 : 1)
                        .animation(listening ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : .default, value: listening)
                    Circle().fill(Color.accentColor)
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: listening)
                }
                .frame(width: 26, height: 26)
                Capsule().fill(.quaternary).frame(height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            half(english: true)
        }
        // The far half's newest line sits at the top; keep it clear of the island.
        .padding(.top, 38)
        .padding(.bottom, 22)
        .frame(width: 200, height: 390)
        .background(Color(.card), in: .rect(cornerRadius: 40, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(bezel, lineWidth: 7)
        }
        .overlay {
            // A hairline rim so the phone stands off a dark background.
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            Capsule().fill(Color(white: 0.12)).frame(width: 52, height: 15).padding(.top, 13)
        }
        .shadow(
            color: colorScheme == .dark ? Color.accentColor.opacity(0.35) : .black.opacity(tilted ? 0.1 : 0.2),
            radius: colorScheme == .dark ? 40 : 20, y: 10
        )
    }

    /// One reader's half: the last two lines, newest at the bottom edge.
    private func half(english: Bool) -> some View {
        let ink = english ? Color(.firstLanguageInk) : Color(.secondLanguageInk)
        return VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            ForEach(max(0, lineCount - 2)..<lineCount, id: \.self) { index in
                let isLatest = index == lineCount - 1
                // Even lines are spoken in English by the near person.
                let ownWords = (index % 2 == 0) == english
                let line = Self.script[index]
                let text = english == (index % 2 == 0) ? line.0 : line.1
                if ownWords || !isLatest || translated {
                    Text(ownWords && isLatest ? String(text.prefix(spokenLength)) : text)
                        .font(.system(size: isLatest ? 14 : 12, weight: isLatest && !ownWords ? .semibold : .regular))
                        .foregroundStyle(ownWords ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink))
                        .opacity(isLatest ? 1 : 0.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    TypingDots(color: ink)
                        .scaleEffect(0.8, anchor: .leading)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .overlay(alignment: .topLeading) {
            Text(english ? "EN" : "中文")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ink.opacity(0.12), in: .capsule)
                .padding(.leading, 14)
        }
    }

    private func play() async {
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.spring(duration: 1.1, bounce: 0.2)) { tilted = true }
        try? await Task.sleep(for: .milliseconds(900))
        while !Task.isCancelled {
            listening = true
            for index in Self.script.indices {
                let spoken = Self.script[index].0
                withAnimation(.snappy) {
                    lineCount = index + 1
                    spokenLength = 0
                    translated = false
                }
                // Chinese has fewer, denser characters; pace both alike.
                let step = spoken.count > 30 ? 2 : 1
                while spokenLength < spoken.count {
                    try? await Task.sleep(for: .milliseconds(index % 2 == 0 ? 45 : 110))
                    guard !Task.isCancelled else { return }
                    spokenLength = min(spoken.count, spokenLength + step)
                }
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.snappy) { translated = true }
                try? await Task.sleep(for: .milliseconds(1800))
            }
            listening = false
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.smooth) { lineCount = 0 }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}
