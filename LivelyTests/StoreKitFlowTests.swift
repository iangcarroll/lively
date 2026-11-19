import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Lively

@MainActor
final class StoreKitFlowTests {
    @Test func purchasesRestoreAndRefundChangeProEntitlement() async throws {
        let file = try #require(Bundle(for: Self.self).url(forResource: "Lively", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: file)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let pro = Pro.shared
        pro.start()
        await pro.loadOffers()
        guard case .ready(let offers) = pro.store else {
            Issue.record("The paywall could not load the local StoreKit catalog.")
            return
        }
        #expect(Set(offers.map(\.id)) == Set(Pro.productIDs))
        #if os(iOS)
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let attribution = AppleAdsAttribution(directory: folder)
        #endif
        for offer in offers {
            session.clearTransactions()
            #if os(iOS)
            let product = try #require(offer.product)
            guard case .success(.verified(let transaction)) = try await product.purchase(options: attribution.purchaseOptions) else {
                Issue.record("StoreKit did not verify the test purchase.")
                return
            }
            let token = try #require(transaction.appAccountToken)
            #expect(attribution.purchaseOptions == [.appAccountToken(token)])
            #else
            let transaction = try await session.buyProduct(identifier: offer.id)
            #endif
            await pro.didBuy(offer, transaction: transaction)
            await pro.restore()
            #expect(pro.subscription?.productID == offer.id)
            #expect(pro.signedTransaction != nil)
            try session.refundTransaction(identifier: UInt(transaction.id))
            // StoreKit delivers the refund to Transaction.updates asynchronously.
            let deadline = ContinuousClock.now + .seconds(8)
            while pro.isSubscribed && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!pro.isSubscribed)
        }
    }
}
