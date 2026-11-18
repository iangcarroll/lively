import Testing
@testable import Lively

struct ConversationModeTests {
    @Test func newInstallsStartAutomatic() {
        #expect(ConversationMode.initial(saved: nil, onboardingDone: false) == .automatic)
    }

    @Test func existingInstallsKeepTheirPair() {
        #expect(ConversationMode.initial(saved: nil, onboardingDone: true) == .pair)
    }

    @Test func aSavedChoiceWins() {
        #expect(ConversationMode.initial(saved: "automatic", onboardingDone: true) == .automatic)
        #expect(ConversationMode.initial(saved: "pair", onboardingDone: false) == .pair)
    }

    @Test func anUnknownSavedValueIsIgnored() {
        #expect(ConversationMode.initial(saved: "duet", onboardingDone: true) == .pair)
    }
}
