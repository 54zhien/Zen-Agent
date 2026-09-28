import Foundation

enum ConversationCardStatus: String, Equatable, Sendable {
    case generating, reasoningVisible, tool, approval, cancelled, failed, authenticationRequired

    static func derive(from projection: RunProjection?, visibleReasoningAllowed: Bool = false) -> Self? {
        // Runnable RED scaffold: the prior repository had no card status API.
        // Replace after compiled mapping cases demonstrate missing behavior.
        guard projection != nil else { return nil }
        return .generating
    }
}
