import SwiftUI

@main
struct LivelyApp: App {
    var body: some Scene {
        WindowGroup {
            ConversationScreen(store: ConversationStore(demo: UserDefaults.standard.bool(forKey: "LivelyDemo")))
                .task {
                    Pro.shared.start()
                    await Account.shared?.refresh()
                }
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        #endif
    }
}
