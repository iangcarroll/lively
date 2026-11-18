import Testing
@testable import Lively

struct ReviewPromptTests {
    @Test func asksAfterTheSecondGoodConversation() {
        #expect(!ReviewPrompt.shouldAsk(turns: 6, goodConversations: 1, alreadyAsked: false))
        #expect(ReviewPrompt.shouldAsk(turns: 6, goodConversations: 2, alreadyAsked: false))
        #expect(ReviewPrompt.shouldAsk(turns: ReviewPrompt.minTurns, goodConversations: 5, alreadyAsked: false))
    }

    @Test func shortConversationsDoNotCount() {
        #expect(!ReviewPrompt.shouldAsk(turns: ReviewPrompt.minTurns - 1, goodConversations: 4, alreadyAsked: false))
    }

    @Test func asksOnlyOnce() {
        #expect(!ReviewPrompt.shouldAsk(turns: 10, goodConversations: 3, alreadyAsked: true))
    }
}
