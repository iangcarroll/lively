import SwiftUI

/// The account card on first launch: `AccountView` with a way to skip it.
struct AccountSheet: View {
    let account: Account
    @Environment(\.dismiss) private var dismiss

    /// Set once the card has opened by itself, so it only does that once.
    static let shownKey = "accountSheetShown"

    var body: some View {
        NavigationStack {
            AccountView(account: account)
                .toolbar {
                    ToolbarItem(placement: account.isSignedIn ? .confirmationAction : .cancellationAction) {
                        Button(account.isSignedIn ? "Done" : "Not Now") { dismiss() }
                    }
                }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}

/// Sign in with an emailed code, or see who's signed in. Pushed from
/// Settings, and the body of `AccountSheet`.
struct AccountView: View {
    let account: Account

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: account.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tint)
                    Text(account.isSignedIn ? "You're signed in" : "Sign in to Lively")
                        .font(.title2.bold())
                    Text("Signing in is optional. It gives you more listening time each day, on every device you use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            AccountSection(account: account)
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
