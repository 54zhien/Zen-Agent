import Foundation
import Testing

@testable import ZenAgent

@Suite("App Space creation ownership")
@MainActor
struct AppSpaceCreationTests {
    @Test("repeated create before projection acceptance reuses one durable ID")
    func repeatedCreationReusesID() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let actions = AppSpaceConversationActions(store: store)
        let first = try actions.create(originID: "origin", at: Fixtures.epoch)
        let retry = try actions.create(originID: "origin", at: Fixtures.epoch.addingTimeInterval(10))
        #expect(first == retry)
        #expect(try store.conversationSummaryPage().items.map(\.id) == [first])
        #expect(try store.conversation(id: first)?.userActiveAt == Fixtures.epoch)
        actions.acknowledgeCreated(id: first)
        let second = try actions.create(originID: "origin", at: Fixtures.epoch.addingTimeInterval(20))
        #expect(second != first)
        #expect(try store.conversationSummaryPage().items.count == 2)
    }

    @Test("failed creation is atomic and an explicit retry creates one history")
    func failedCreationRetainsRetry() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let actions = AppSpaceConversationActions(store: store)
        try store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER new_failure BEFORE INSERT ON conversation BEGIN SELECT RAISE(ABORT, 'test create failure'); END")
        }
        #expect(throws: (any Error).self) { try actions.create(originID: "origin", at: Fixtures.epoch) }
        #expect(actions.errorMessage != nil)
        #expect(try store.conversationSummaryPage().items.isEmpty)
        try store.database.write { db in try db.execute(sql: "DROP TRIGGER new_failure") }
        let id = try actions.create(originID: "origin", at: Fixtures.epoch)
        #expect(try store.conversationSummaryPage().items.map(\.id) == [id])
        #expect(actions.errorMessage == nil)
    }
}
