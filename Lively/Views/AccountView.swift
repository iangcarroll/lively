import SwiftUI

/// Sign in with an emailed code, or see who's signed in. Pushed from
/// Settings; its content is also the last step of onboarding.
struct AccountView: View {
    let account: Account

    var body: some View {
        ScrollView {
            AccountContent(account: account)
                .padding(.top, 24)
                .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.canvas))
        .navigationTitle("Account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The account screen's body: a header, then either the sign-in steps or
/// who's signed in.
struct AccountContent: View {
    let account: Account

    var body: some View {
        VStack(spacing: 32) {
            header
            if let email = account.email {
                SignedInCard(account: account, email: email)
            } else {
                SignInForm(account: account)
                benefits
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: account.isSignedIn)
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(.firstLanguageInk), Color(red: 0.55, green: 0.29, blue: 0.6), Color(.secondLanguageInk)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                if let email = account.email, let initial = email.first {
                    Text(String(initial).uppercased())
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 32, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .shadow(color: Color(.firstLanguageInk).opacity(0.3), radius: 14, y: 6)

            VStack(spacing: 6) {
                Text(account.isSignedIn ? "You're signed in" : "Sign in to Lively")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text(account.isSignedIn
                    ? "Your translation time follows you to every device you sign in on."
                    : "Optional, and it takes a few seconds. Signing in gives you more translation time every day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 18) {
            BenefitRow(systemImage: "timer", color: .orange, title: "More translation time",
                       detail: "A bigger daily allowance than without an account.")
            BenefitRow(systemImage: "iphone.gen3", color: .blue, title: "On all your devices",
                       detail: "Sign in on each one; your allowance comes along.")
            BenefitRow(systemImage: "envelope.fill", color: .green, title: "No password to remember",
                       detail: "We email you a 6-digit code each time.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct BenefitRow: View {
    let systemImage: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SignedInCard: View {
    let account: Account
    let email: String
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 16) {
            card
            deleteButton
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: "envelope.fill", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Email").font(.caption).foregroundStyle(.secondary)
                    Text(email).font(.body).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Verified")
            }
            .padding(16)
            if account.hasFreePro {
                Divider().padding(.leading, 58)
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "star.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lively Pro").font(.body)
                        Text("Included free with your account").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            }
            Divider().padding(.leading, 58)
            Button(role: .destructive) { confirmingSignOut = true } label: {
                Text("Sign Out")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .background(Color(.card), in: .rect(cornerRadius: 24, style: .continuous))
        .confirmationDialog("Sign out of Lively?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { account.signOut() }
        } message: {
            Text("You'll go back to this device's daily translation time.")
        }
    }

    private var deleteButton: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) { confirmingDelete = true } label: {
                ZStack {
                    Text("Delete Account").opacity(deleting ? 0 : 1)
                    if deleting { ProgressView() }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(deleting)
            if let deleteError {
                Label(deleteError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .confirmationDialog("Delete your Lively account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive, action: delete)
        } message: {
            Text(account.hasFreePro
                ? "This erases your email and account from Lively's servers, including the free Lively Pro that came with it. It can't be undone."
                : "This erases your email and account from Lively's servers and can't be undone. It doesn't cancel a Lively Pro subscription.")
        }
    }

    private func delete() {
        deleting = true
        deleteError = nil
        Task {
            defer { deleting = false }
            do {
                try await account.deleteAccount()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

/// Two steps, one action each: type an email and continue, then type the
/// code, which signs in by itself once all six digits are there.
private struct SignInForm: View {
    let account: Account

    @State private var email = ""
    @State private var code = ""
    /// The address a code was sent to, while waiting for it.
    @State private var codeSentTo: String?
    @State private var working = false
    @State private var errorMessage: String?
    /// Bumped on a wrong code to shake the boxes.
    @State private var shakes = 0
    @State private var resendAvailableAt = Date.distantPast
    @FocusState private var focused: Bool

    private static let resendDelay: TimeInterval = 30

    var body: some View {
        VStack(spacing: 14) {
            if let sentTo = codeSentTo {
                codeStep(sentTo)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            } else {
                emailStep
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)).combined(with: .opacity))
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: codeSentTo)
        .animation(.snappy, value: errorMessage)
    }

    // MARK: Email

    private var emailStep: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "at")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(focused ? Color.accentColor : .secondary)
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit(sendCode)
                    .onChange(of: email) { errorMessage = nil }
                    .accessibilityLabel("Email")
            }
            .font(.body)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Color(.card), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1)
            }
            .animation(.snappy(duration: 0.2), value: focused)

            Button(action: sendCode) {
                ZStack {
                    Text("Email Me a Code").opacity(working ? 0 : 1)
                    if working { ProgressView().tint(.white) }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(.capsule)
            }
            .buttonStyle(PressableCapsule())
            .disabled(!isPlausibleEmail || working)
        }
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isPlausibleEmail: Bool {
        let parts = trimmedEmail.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }

    // MARK: Code

    private func codeStep(_ sentTo: String) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Enter the code we emailed to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(sentTo)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            CodeBoxes(code: $code, isError: errorMessage != nil, working: working, focused: $focused)
                .modifier(Shake(amount: CGFloat(shakes)))
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    if !digits.isEmpty { errorMessage = nil }
                }
                // Signs in once all six digits are there. A task, not
                // onChange, so a fast paste or autofill can't skip it.
                .task(id: code) {
                    if code.count == 6, code.allSatisfy(\.isNumber) { signIn() }
                }

            HStack(spacing: 0) {
                Button("Change Email", systemImage: "chevron.left") {
                    codeSentTo = nil
                    code = ""
                    errorMessage = nil
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 18)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "Resend in \(wait)s" : "Resend Code", systemImage: "arrow.clockwise") {
                        send(to: sentTo)
                    }
                    .disabled(wait > 0)
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)
            .labelStyle(.titleOnly)
            .disabled(working)
        }
        .task {
            // Wait for the email field to leave, or it takes the focus with it.
            try? await Task.sleep(for: .milliseconds(400))
            focused = true
        }
    }

    // MARK: Actions

    private func sendCode() {
        guard isPlausibleEmail, !working else { return }
        send(to: trimmedEmail)
    }

    private func send(to address: String) {
        run {
            try await account.sendCode(to: address)
            codeSentTo = address
            code = ""
            resendAvailableAt = .now + Self.resendDelay
        }
    }

    private func signIn() {
        guard let codeSentTo, !working else { return }
        let entered = code
        run {
            do {
                try await account.signIn(email: codeSentTo, code: entered)
            } catch {
                code = ""
                withAnimation(.default) { shakes += 1 }
                throw error
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Six boxes over one invisible text field, so paste and the keyboard's
/// one-time-code suggestion both work.
private struct CodeBoxes: View {
    @Binding var code: String
    let isError: Bool
    let working: Bool
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .focused(focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel("6-digit code")

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    box(index)
                    if index == 2 {
                        Capsule().fill(.tertiary).frame(width: 8, height: 2)
                    }
                }
            }
            .allowsHitTesting(false)
            .opacity(working ? 0.5 : 1)
            .overlay { if working { ProgressView() } }
        }
        .contentShape(.rect)
        .onTapGesture { focused.wrappedValue = true }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(code)
        let filled = index < digits.count
        let active = focused.wrappedValue && index == min(digits.count, 5) && !working
        return Text(filled ? String(digits[index]) : "")
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .frame(maxWidth: 50)
            .frame(height: 60)
            .background(Color(.card), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isError ? Color.red : active ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isError || active ? 1.5 : 1
                    )
            }
            .overlay {
                if active && !filled {
                    Caret()
                }
            }
            .animation(.snappy(duration: 0.15), value: filled)
    }
}

private struct Caret: View {
    @State private var on = true

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 26)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false }
            }
    }
}

nonisolated private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}
