import SwiftUI

/// Sign in with an emailed code, for a bigger daily listening budget.
/// Shown in `AccountView`.
struct AccountSection: View {
    let account: Account

    @State private var email = ""
    @State private var code = ""
    /// The address a code was sent to, while waiting for it.
    @State private var codeSentTo: String?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let signedIn = account.email {
                LabeledContent("Signed in as", value: signedIn)
                Button("Sign Out", role: .destructive) { account.signOut() }
            } else if let sentTo = codeSentTo {
                TextField("6-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit(signIn)
                    .onChange(of: code) { if digits(code).count == 6 { signIn() } }
                Button("Sign In", action: signIn)
                    .disabled(working || digits(code).count != 6)
                Button("Use a Different Email") {
                    codeSentTo = nil
                    code = ""
                    errorMessage = nil
                }
                .disabled(working)
                Button("Send Another Code") { sendCode(to: sentTo) }
                    .disabled(working)
            } else {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { sendCode(to: email) }
                Button("Email Me a Code") { sendCode(to: email) }
                    .disabled(working || !email.contains("@"))
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if account.isSignedIn {
                Text("Listening time is counted for your account on every device you sign in on.")
            } else if let codeSentTo {
                Text("Enter the code sent to \(codeSentTo).")
            }
        }
    }

    private func digits(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    private func sendCode(to address: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            try await account.sendCode(to: address)
            codeSentTo = address
            code = ""
        }
    }

    private func signIn() {
        guard let codeSentTo, !working else { return }
        let entered = digits(code)
        run {
            try await account.signIn(email: codeSentTo, code: entered)
            self.codeSentTo = nil
            code = ""
            email = ""
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
