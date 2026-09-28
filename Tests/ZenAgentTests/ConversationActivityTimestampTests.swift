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
        #expect(try store.conversation(id: "a")?.createdAt == t1)
        #expect(try store.conversation(id: "a")?.updatedAt == t3)
    }

    @Test("a stale snapshot preserves current metadata and an older action cannot move activity backward")
    func staleSnapshotAndOlderAction() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = t1.addingTimeInterval(60)
        var first = Fixtures.send(messageID: "m1", runID: "r1", runState: .completed)
        first.conversation.createdAt = t1
        first.conversation.updatedAt = t2
        first.conversation.userActiveAt = t2
        first.message.createdAt = t1
        try store.commitUserTurnAndCreateParentRun(first)
        let stale = try #require(try store.conversation(id: "c1"))
        try store.database.write { db in
            try db.execute(sql: "UPDATE conversation SET title = 'Latest title', pinned = 1 WHERE id = 'c1'")
        }

        var second = Fixtures.send(messageID: "m2", runID: "r2", runState: .completed)
        second.conversation = stale
        second.message.sequence = 1
        second.message.createdAt = t1.addingTimeInterval(30)
        try store.commitUserTurnAndCreateParentRun(second)

        let after = try #require(try store.conversation(id: "c1"))
        #expect(after.title == "Latest title")
        #expect(after.pinned)
        #expect(after.createdAt == t1)
        #expect(after.updatedAt == t2)
        #expect(after.userActiveAt == t2)
    }

    @Test("duplicate submission and late constraint failure leave activity unchanged")
    func replayAndFailedCommitDoNotAdvanceActivity() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = t1.addingTimeInterval(60)
        var first = Fixtures.send(messageID: "m1", runID: "r1", runState: .completed)
        first.conversation.createdAt = t1
        first.conversation.updatedAt = t1
        first.conversation.userActiveAt = t1
        first.message.createdAt = t1
        first.run.submissionID = "same-submission"
        first.run.submissionDigest = "same-payload"
        try store.commitUserTurnAndCreateParentRun(first)

        var replay = Fixtures.send(messageID: "m2", runID: "r2", runState: .completed)
        replay.message.createdAt = t2
        replay.run.submissionID = "same-submission"
        replay.run.submissionDigest = "same-payload"
        #expect(try store.commitUserTurnAndCreateParentRun(replay) == "r1")

        var failed = Fixtures.send(messageID: "m3", runID: "r3", runState: .completed)
        failed.conversation = try #require(try store.conversation(id: "c1"))
        failed.message.sequence = 1
        failed.message.createdAt = t2
        failed.parts = [
            Fixtures.textPart(id: "duplicate-part", messageID: "m3", sequence: 0),
            Fixtures.textPart(id: "duplicate-part", messageID: "m3", sequence: 1)
        ]
        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(failed)
        } catch {
            failure = error
        }

        #expect(failure != nil)
        #expect(try store.conversation(id: "c1")?.userActiveAt == t1)
        #expect(try store.conversation(id: "c1")?.updatedAt == t1)
        #expect(try store.messages(inConversation: "c1").map(\.id) == ["m1"])
        #expect(try store.run(id: "r2") == nil)
        #expect(try store.run(id: "r3") == nil)
    }

    @Test("repeat-send ordering survives closing and reopening the database")
    func recentOrderSurvivesDatabaseReopen() throws {
        let url = try Fixtures.scratchPath(name: "recent-activity.sqlite")
        defer { Fixtures.cleanUp(url) }
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = t1.addingTimeInterval(60)
        let t3 = t2.addingTimeInterval(60)
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            var firstA = Fixtures.send(conversationID: "a", messageID: "a1", runID: "ar1", runState: .completed)
            firstA.conversation.userActiveAt = t1
            firstA.message.createdAt = t1
            try store.commitUserTurnAndCreateParentRun(firstA)
            var firstB = Fixtures.send(conversationID: "b", messageID: "b1", runID: "br1", runState: .completed)
            firstB.conversation.userActiveAt = t2
            firstB.message.createdAt = t2
            try store.commitUserTurnAndCreateParentRun(firstB)
            var secondA = Fixtures.send(conversationID: "a", messageID: "a2", runID: "ar2", runState: .completed)
            secondA.message.sequence = 1
            secondA.message.createdAt = t3
            try store.commitUserTurnAndCreateParentRun(secondA)
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        #expect(try reopened.visibleConversations().map(\.id) == ["a", "b"])
        #expect(try reopened.conversation(id: "a")?.userActiveAt == t3)
    }
}
