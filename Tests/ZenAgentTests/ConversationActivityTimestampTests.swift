import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation activity timestamps")
struct ConversationActivityTimestampTests {
    @Test("sending again moves a conversation ahead of a more recently created one")
    func repeatSendMovesConversationToTop() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = t1.addingTimeInterval(60)
        let t3 = t2.addingTimeInterval(60)

        var firstA = Fixtures.send(conversationID: "a", messageID: "a1", runID: "ar1", runState: .completed)
        firstA.conversation.createdAt = t1
        firstA.conversation.updatedAt = t1
        firstA.conversation.userActiveAt = t1
        firstA.message.createdAt = t1
        try store.commitUserTurnAndCreateParentRun(firstA)

        var firstB = Fixtures.send(conversationID: "b", messageID: "b1", runID: "br1", runState: .completed)
        firstB.conversation.createdAt = t2
        firstB.conversation.updatedAt = t2
        firstB.conversation.userActiveAt = t2
        firstB.message.createdAt = t2
        try store.commitUserTurnAndCreateParentRun(firstB)

        var secondA = Fixtures.send(conversationID: "a", messageID: "a2", runID: "ar2", runState: .completed)
        secondA.conversation = try #require(try store.conversation(id: "a"))
        secondA.message.sequence = 1
        secondA.message.createdAt = t3
        try store.commitUserTurnAndCreateParentRun(secondA)

        #expect(try store.visibleConversations().map(\.id) == ["a", "b"])
        #expect(try store.conversation(id: "a")?.userActiveAt == t3)
    }
}
