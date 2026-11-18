import Foundation
import Testing
@testable import Lively

/// The yearly plan's badge on the Lively Pro screen.
struct ProTests {
    private func badge(yearly: String, monthly: String) -> String? {
        Pro.savingBadge(yearly: Decimal(string: yearly)!, monthly: Decimal(string: monthly)!)
    }

    @Test func savingIsAgainstTwelveMonths() {
        #expect(badge(yearly: "39.99", monthly: "4.99") == "Save 33%")
        #expect(badge(yearly: "30", monthly: "5") == "Save 50%")
    }

    /// 33.2% is "Save 33%", and so is 33.9%: the badge never overstates.
    @Test func savingRoundsDown() {
        #expect(badge(yearly: "39.66", monthly: "5") == "Save 33%")
    }

    @Test func smallSavingsGetNoBadge() {
        #expect(badge(yearly: "57.50", monthly: "4.99") == nil)
        #expect(badge(yearly: "57", monthly: "5") == "Save 5%")
    }

    @Test func noBadgeWithoutASaving() {
        #expect(badge(yearly: "59.88", monthly: "4.99") == nil)
        #expect(badge(yearly: "70", monthly: "4.99") == nil)
        #expect(badge(yearly: "39.99", monthly: "0") == nil)
    }
}
