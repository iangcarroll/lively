import StoreKit
import SwiftUI

/// Lively Pro: subscribe, restore, or see what you have. Pushed from
/// Settings, and shown when a free day's translation time runs out.
///
/// The allowances here match the key broker's limits in `wrangler.jsonc`.
struct ProView: View {
    /// Shown because today's free time ran out, not opened from Settings.
    var limitReached = false

    private let pro = Pro.shared
    @State private var managing = false
    /// The chosen plan; until one is tapped, the first, which is yearly.
    @State private var selected: Pro.Offer.ID?
    @State private var buying = false
    @State private var restoring = false
    @State private var errorMessage: String?
    @Environment(\.purchase) private var purchase

    var body: some View {
        Group {
            if pro.isSubscribed {
                status(
                    title: "You have Lively Pro",
                    detail: pro.subscription?.expirationDate.map { "Active through \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "",
                    manage: pro.subscription != nil
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

    /// Signing in is the free way past a used-up day, where there's an
    /// account service and nobody is signed in.
    private var signInAccount: Account? {
        guard limitReached, let account = Account.shared, !account.isSignedIn else { return nil }
        return account
    }

    // StoreKit's own subscription view put the second plan under its
    // Subscribe button and can't show a saving, so the plans are drawn here,
    // as on Android: the header scrolls, and the plans and Subscribe stay
    // in view below it.
    private var store: some View {
        ScrollView {
            Group {
                if limitReached {
                    // The subtitle says what Pro gives; the rows would only
                    // push the plans off a small screen.
                    ProHeader(
                        title: "That's today's free time",
                        subtitle: signInAccount == nil
                            ? "Free translation is back tomorrow. Lively Pro gives you 10 hours a day."
                            : "Free translation is back tomorrow. Sign in for another hour today, or get 10 hours a day with Pro.",
                        showsBenefits: false
                    )
                } else {
                    ProHeader()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The bar is the same canvas as the page, so the plans don't sit on
        // a panel of their own; a short fade softens a header scrolled under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseBar
                .background(Color(.canvas))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color(.canvas).opacity(0), Color(.canvas)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .offset(y: -20)
                        .allowsHitTesting(false)
                }
        }
        .background(Color(.canvas))
        .task { await pro.loadOffers() }
    }

    private var purchaseBar: some View {
        VStack(spacing: 12) {
            switch pro.store {
            case .loading:
                ProgressView().frame(minHeight: 120)
            case .unavailable(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 120)
            case .ready(let offers):
                let chosen = offers.first { $0.id == selected } ?? offers.first
                VStack(spacing: 10) {
                    ForEach(offers) { offer in
                        PlanCard(offer: offer, selected: offer.id == chosen?.id) { selected = offer.id }
                    }
                }
                if let chosen {
                    Button { buy(chosen) } label: {
                        ZStack {
                            Text("Subscribe").opacity(buying ? 0 : 1)
                            if buying { ProgressView().tint(.white) }
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(PressableCapsule())
                    .disabled(buying)
                    Text("\(chosen.price) per \(chosen.period). Renews automatically until you cancel in your Apple Account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if let signInAccount {
                NavigationLink("Sign in for another free hour") { AccountView(account: signInAccount) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 36)
            }
            HStack(spacing: 18) {
                Button(restoring ? "Restoring…" : "Restore Purchases", action: restore)
                    .disabled(restoring)
                Link("Terms of Use", destination: Links.terms)
                Link("Privacy Policy", destination: Links.privacy)
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: selected)
    }

    private func buy(_ offer: Pro.Offer) {
        buying = true
        errorMessage = nil
        Task {
            defer { buying = false }
            guard let product = offer.product else { return await pro.didBuy(offer, transaction: nil) }
            do {
                #if os(iOS)
                let options = AppleAdsAttribution.shared.purchaseOptions
                #else
                let options: Set<Product.PurchaseOption> = []
                #endif
                switch try await purchase(product, options: options) {
                case .success(.verified(let transaction)): await pro.didBuy(offer, transaction: transaction)
                case .success(.unverified): errorMessage = "The App Store couldn't verify that purchase."
                // Waiting on Ask to Buy, or closed without buying.
                case .pending, .userCancelled: break
                @unknown default: break
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        restoring = true
        errorMessage = nil
        Task {
            await pro.restore()
            restoring = false
            if !pro.isSubscribed { errorMessage = "No Lively Pro subscription was found for this Apple Account." }
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

/// One plan: its name, what it saves, and its price.
private struct PlanCard: View {
    let offer: Pro.Offer
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(offer.title).font(.headline)
                        if let badge = offer.badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: .capsule)
                        }
                    }
                    Text("\(offer.price) per \(offer.period)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color(.card), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum Links {
    static let terms = URL(string: "https://lively.cautela.hk/terms")!
    static let privacy = URL(string: "https://lively.cautela.hk/privacy")!
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

private struct ProHeader: View {
    var title = "Lively Pro"
    var subtitle = "Translate for hours, every day."
    var showsBenefits = true

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(
                        LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .circle
                    )
                    .shadow(color: .orange.opacity(0.3), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsBenefits {
                VStack(alignment: .leading, spacing: 16) {
                    row("timer", .orange, "10 hours a day", "Free gives you an hour a day, or two when you're signed in.")
                    row("iphone.gen3", .blue, "On all your devices", "Pro comes with your Apple Account. No sign-in needed.")
                    row("arrow.uturn.backward", .green, "Cancel anytime", "Manage it in your Apple Account's Subscriptions.")
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
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
