import Foundation
import Observation
import StoreKit

/// Lively Pro: a bigger daily translation allowance, from an App Store
/// subscription or, for some accounts, for free (`Account.hasFreePro`).
///
/// The broker decides what each key allows (`Server/key-broker/src/appstore.ts`).
/// The app sends it the current subscription's signed transaction, which
/// StoreKit keeps current across renewals, restores and other devices.
@Observable
final class Pro {
    static let shared = Pro()

    /// The subscription group's products, shortest first. They must match the
    /// broker's `APP_STORE_PRODUCT_IDS`.
    static let productIDs = ["hk.cautela.lively.pro.monthly", "hk.cautela.lively.pro.yearly"]

    /// The active subscription, if there is one.
    private(set) var subscription: StoreKit.Transaction?
    /// Its JWS, sent to the broker as `Lively-Subscription`.
    @ObservationIgnored private(set) var signedTransaction: String?
    /// Set when a free day's allowance runs out, so the app can offer Pro.
    var freeLimitReached = false

    /// One way to pay, as the store shows it.
    struct Offer: Identifiable {
        let id: String
        let title: String
        let price: String
        let period: String
        /// What the yearly plan saves against twelve months, e.g. "Save 33%".
        let badge: String?
        let product: Product?
    }

    enum StoreState {
        case loading
        case ready([Offer])
        case unavailable(String)
    }

    private(set) var store = StoreState.loading
    /// A demo-mode purchase, so screenshots can show the subscribed state.
    private var demoSubscribed = false

    var isSubscribed: Bool { subscription != nil || demoSubscribed }
    var isPro: Bool { isSubscribed || Account.shared?.hasFreePro == true }

    @ObservationIgnored private var updates: Task<Void, Never>?

    private init() {}

    /// Follows purchases, renewals, refunds and purchases made on other
    /// devices. Call once at launch.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// Reads the current entitlement from StoreKit.
    func refresh() async {
        var newest: (transaction: StoreKit.Transaction, jws: String)?
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > .now }) ?? false
            else { continue }
            if newest.map({ transaction.expirationDate! > $0.transaction.expirationDate! }) ?? true {
                newest = (transaction, entitlement.jwsRepresentation)
            }
        }
        let changed = newest?.jws != signedTransaction
        subscription = newest?.transaction
        signedTransaction = newest?.jws
        if isSubscribed { freeLimitReached = false }
        // A spare key minted on the old plan carries the old plan's limits.
        if changed { SonioxKeyProvider.shared?.dropSpare() }
    }

    /// Reads the plans and their prices from the App Store.
    func loadOffers() async {
        if Self.isDemo {
            store = .ready(Self.demoOffers)
            return
        }
        do {
            let products = try await Product.products(for: Self.productIDs)
            store = products.isEmpty
                ? .unavailable(String(localized: "Lively Pro isn't available from the App Store on this device yet."))
                : .ready(Self.offers(products))
        } catch {
            store = .unavailable(String(localized: "Couldn't reach the App Store. Check your connection and try again."))
        }
    }

    /// Records a finished purchase. In demo mode, which has no store, any
    /// purchase succeeds.
    func didBuy(_ offer: Offer, transaction: StoreKit.Transaction?) async {
        if Self.isDemo {
            demoSubscribed = true
            freeLimitReached = false
            return
        }
        await transaction?.finish()
        await refresh()
    }

    /// Asks the App Store again for what this Apple Account owns.
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Yearly first, which is also the plan that starts selected.
    static func offers(_ products: [Product]) -> [Offer] {
        let monthly = products.first { $0.subscription?.subscriptionPeriod.unit == .month }?.price
        return products
            .sorted { ($0.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) < ($1.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) }
            .map { product in
                let yearly = product.subscription?.subscriptionPeriod.unit == .year
                return Offer(
                    id: product.id,
                    title: yearly ? String(localized: "Yearly") : String(localized: "Monthly"),
                    price: product.displayPrice,
                    period: yearly ? String(localized: "year") : String(localized: "month"),
                    badge: yearly ? monthly.flatMap { savingBadge(yearly: product.price, monthly: $0) } : nil,
                    product: product
                )
            }
    }

    /// What a year costs less than twelve months, rounded down so it never
    /// overstates. Nothing under 5%, which isn't worth a badge.
    static func savingBadge(yearly: Decimal, monthly: Decimal) -> String? {
        let twelveMonths = monthly * 12
        guard twelveMonths > 0, yearly < twelveMonths else { return nil }
        var fraction = (twelveMonths - yearly) * 100 / twelveMonths
        var floored = Decimal()
        NSDecimalRound(&floored, &fraction, 0, .down)
        let saving = NSDecimalNumber(decimal: floored).intValue
        return saving >= 5 ? String(localized: "Save \(saving)%") : nil
    }

    private static var isDemo: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "LivelyDemo")
        #else
        false
        #endif
    }

    /// `Config/Lively.storekit`'s local test prices, for demo mode.
    private static let demoOffers = [
        Offer(id: "hk.cautela.lively.pro.yearly", title: String(localized: "Yearly"), price: "$39.99", period: String(localized: "year"), badge: String(localized: "Save 33%"), product: nil),
        Offer(id: "hk.cautela.lively.pro.monthly", title: String(localized: "Monthly"), price: "$4.99", period: String(localized: "month"), badge: nil, product: nil),
    ]
}
