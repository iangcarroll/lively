import AuthenticationServices
import SwiftUI

@main
struct LivelyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if AppSettings.shared.onlineProcessing == nil {
                OnlineProcessingChoice(settings: .shared)
            } else {
                ConversationScreen(store: makeStore())
                    .task {
                        Pro.shared.start()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                        Task { await Account.shared?.refreshAppleCredential() }
                    }
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        await Account.shared?.refreshAppleCredential()
                        await Account.shared?.refresh()
                    }
            }
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        #endif
    }

    private func makeStore() -> ConversationStore {
        #if DEBUG
        ConversationStore(demo: UserDefaults.standard.bool(forKey: "LivelyDemo"))
        #else
        ConversationStore()
        #endif
    }
}
