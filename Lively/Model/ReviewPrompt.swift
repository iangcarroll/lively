import Foundation

/// When to ask for a store review: once, after a couple of conversations
/// long enough to have been useful. The store decides whether to show it.
enum ReviewPrompt {
    /// Finished turns that make a conversation count.
    static let minTurns = 4
    /// Such conversations before asking, counting the one that just ended.
    static let conversationsBeforeAsking = 2

    static func shouldAsk(turns: Int, goodConversations: Int, alreadyAsked: Bool) -> Bool {
        !alreadyAsked && turns >= minTurns && goodConversations >= conversationsBeforeAsking
    }
}
