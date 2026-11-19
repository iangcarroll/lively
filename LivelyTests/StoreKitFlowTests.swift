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
        for offer in offers {
            session.clearTransactions()
            let transaction = try await session.buyProduct(identifier: offer.id)
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
