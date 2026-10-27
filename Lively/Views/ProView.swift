import StoreKit
import SwiftUI

/// Lively Pro: subscribe, restore, or see what you have. Pushed from
/// Settings, and shown when a free day's translation time runs out.
///
/// The allowances here match the key broker's limits in `wrangler.jsonc`.
struct ProView: View {
    private let pro = Pro.shared
    @State private var managing = false

    var body: some View {
        Group {
            if let subscription = pro.subscription {
                status(
                    title: "You have Lively Pro",
                    detail: subscription.expirationDate.map { "Active through \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "",
                    manage: true
                )
            } else if Account.shared?.hasFreePro == true {
                status(title: "You have Lively Pro", detail: "It's included free with your account.", manage: false)
            } else {
                store
            }
        }
        .navigationTitle("Lively Pro")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
        .task { await pro.refresh() }
    }

    private var store: some View {
        SubscriptionStoreView(productIDs: Pro.productIDs) {
            ProHeader()
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .containerBackground(Color(.canvas).gradient, for: .subscriptionStoreFullHeight)
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        // The screen is pushed or has its own Done button.
        .storeButton(.hidden, for: .cancellation)
        .subscriptionStorePolicyDestination(url: Links.terms, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Links.privacy, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(.verified(let transaction))) = result { await transaction.finish() }
            await pro.refresh()
        }
    }

    private func status(title: String, detail: String, manage: Bool) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                ProHeader(title: title, subtitle: detail)
                if manage {
                    Button {
                        #if os(iOS)
                        managing = true
                        #else
                        NSWorkspace.shared.open(Links.manageSubscriptions)
                        #endif
                    } label: {
                        Text("Manage Subscription")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressableCapsule())
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.canvas))
    }
}

enum Links {
    static let terms = URL(string: "https://lively.ian.sh/terms")!
    static let privacy = URL(string: "https://lively.ian.sh/privacy")!
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

private struct ProHeader: View {
    var title = "Lively Pro"
    var subtitle = "Translate for hours, every day."

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                Image(systemName: "star.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    .shadow(color: .orange.opacity(0.3), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                row("timer", .orange, "10 hours a day", "Free gives you an hour a day, or two when you're signed in.")
                row("iphone.gen3", .blue, "On all your devices", "Pro comes with your Apple Account. No sign-in needed.")
                row("arrow.uturn.backward", .green, "Cancel anytime", "Manage it in your Apple Account's Subscriptions.")
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func row(_ systemImage: String, _ color: Color, _ title: String, _ detail: String) -> some View {
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
