package sh.ian.lively.model

/**
 * When to ask for a store review: after a conversation that went well, once.
 * The app asks through Google Play's in-app review flow; iOS mirrors this
 * with StoreKit's `requestReview`. Both stores decide whether the prompt is
 * actually shown.
 */
object ReviewPrompt {
    /** Finished turns that make a conversation count as a good one. */
    const val MIN_TURNS = 4

    /** Good conversations, this one included, before asking. */
    const val CONVERSATIONS_BEFORE_ASKING = 2

    /**
     * Whether to ask now that listening has stopped. [turns] is the
     * conversation's finished turns, and [goodConversations] counts this one.
     */
    fun shouldAsk(turns: Int, goodConversations: Int, alreadyAsked: Boolean): Boolean =
        !alreadyAsked && turns >= MIN_TURNS && goodConversations >= CONVERSATIONS_BEFORE_ASKING
}
