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
    /// broker's `PRO_PRODUCT_IDS`.
    static let productIDs = ["sh.ian.lively.pro.monthly", "sh.ian.lively.pro.yearly"]

    /// The active subscription, if there is one.
    private(set) var subscription: StoreKit.Transaction?
    /// Its JWS, sent to the broker as `Lively-Subscription`.
    @ObservationIgnored private(set) var signedTransaction: String?
    /// Set when a free day's allowance runs out, so the app can offer Pro.
    var freeLimitReached = false

    var isSubscribed: Bool { subscription != nil }
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
}
