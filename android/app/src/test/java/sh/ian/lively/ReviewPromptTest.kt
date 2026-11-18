package sh.ian.lively

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.ReviewPrompt

class ReviewPromptTest {
    @Test fun asksAfterTheSecondGoodConversation() {
        assertTrue(ReviewPrompt.shouldAsk(turns = 4, goodConversations = 2, alreadyAsked = false))
        assertTrue(ReviewPrompt.shouldAsk(turns = 12, goodConversations = 5, alreadyAsked = false))
    }

    @Test fun doesNotAskAfterTheFirst() {
        assertFalse(ReviewPrompt.shouldAsk(turns = 8, goodConversations = 1, alreadyAsked = false))
    }

    @Test fun doesNotAskAfterAShortConversation() {
        assertFalse(ReviewPrompt.shouldAsk(turns = 3, goodConversations = 2, alreadyAsked = false))
        assertFalse(ReviewPrompt.shouldAsk(turns = 0, goodConversations = 9, alreadyAsked = false))
    }

    @Test fun asksOnlyOnce() {
        assertFalse(ReviewPrompt.shouldAsk(turns = 4, goodConversations = 2, alreadyAsked = true))
        assertFalse(ReviewPrompt.shouldAsk(turns = 20, goodConversations = 20, alreadyAsked = true))
    }
}
