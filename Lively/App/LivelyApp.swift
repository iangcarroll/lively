import AuthenticationServices
import SwiftUI

@main
struct LivelyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ConversationScreen(store: makeStore())
                .task {
                    Pro.shared.start()
                }
                #if os(iOS)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await AppleAdsAttribution.shared.collect()
                }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                    Task { await Account.shared?.refreshAppleCredential() }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await Account.shared?.refreshAppleCredential()
                    await Account.shared?.refresh()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: AppUsage.shared?.foreground(true)
            case .background: AppUsage.shared?.foreground(false)
            #if os(macOS)
            case .inactive: AppUsage.shared?.foreground(false)
            #endif
            default: break
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
