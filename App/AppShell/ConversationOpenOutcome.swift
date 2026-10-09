import Foundation

enum ConversationOpenOutcome: Equatable, Sendable {
    case opened(conversationID: String)
    case cancelled(conversationID: String)
    case failed(RecentConversationOpenFailure)

    var isOpened: Bool {
        if case .opened = self { return true }
        return false
    }
}
