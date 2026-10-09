import Foundation
import Testing

@testable import ZenAgent

@Suite("App Space New entry")
@MainActor
struct AppSpaceNewEntryTests {
    @Test("New is after newest history and returning from it keeps at most five summaries")
    func newIsDistinctAndRightmost() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            for index in 0..<100 {
                var row = Fixtures.conversation(id: "new-\(index)")
                row.userActiveAt = Fixtures.epoch.addingTimeInterval(Double(index))
                try row.insert(db)
            }
        }
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: {
            ConversationBrowseWindow(current: nil, older: try store.conversationSummaryPage(limit: 3).items, newer: nil)
        })
        browse.present(originID: "new-99")
        #expect(browse.state.selected == .conversation("new-99"))
        #expect(browse.state.newer == .newConversation)
        #expect(browse.begin())
        #expect(browse.drag(displacement: -200, travel: 300))
        let forward = try #require(browse.end(velocity: -1000, travel: 300))
        #expect(browse.complete(forward, finished: true))
        #expect(browse.isNewEntry)
        #expect(browse.selectedConversationID == nil)
        #expect(browse.state.newer == nil)
        #expect(browse.state.older == .conversation("new-99"))
        #expect(browse.summaries.count <= 3)
        #expect(browse.begin())
        #expect(browse.drag(displacement: 200, travel: 300))
        let back = try #require(browse.end(velocity: 0, travel: 300))
        #expect(browse.complete(back, finished: true))
        #expect(browse.state.selected == .conversation("new-99"))
        #expect(browse.summaries.count <= 5)
        #expect(!browse.complete(forward, finished: true))
    }

    @Test("explicitly created history selection rejects stale motion completion and becomes a normal card")
    func createdSelectionInvalidatesMotion() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            try Fixtures.conversation(id: "origin").insert(db)
            try Fixtures.conversation(id: "created").insert(db)
        }
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: { ConversationBrowseWindow(current: nil, older: try store.conversationSummaryPage(limit: 3).items, newer: nil) })
        browse.present(originID: "origin")
        #expect(browse.begin())
        #expect(browse.drag(displacement: -200, travel: 300))
        let obsolete = try #require(browse.end(velocity: 0, travel: 300))
        #expect(browse.selectCreatedConversation(id: "created"))
        #expect(browse.state.selected == .conversation("created"))
        #expect(!browse.isNewEntry && browse.selectedConversationID == "created")
        #expect(!browse.complete(obsolete, finished: true))
        #expect(browse.summaries.count <= 5)
    }

    @Test("New read failure retains the committed original selection and window")
    func newReadFailureKeepsOrigin() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in try Fixtures.conversation().insert(db) }
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: { throw PersistenceError.invalidTransition("test read failure") })
        browse.present(originID: "c1")
        let before = browse.summaries
        #expect(browse.begin())
        #expect(browse.drag(displacement: -200, travel: 300))
        let settlement = try #require(browse.end(velocity: 0, travel: 300))
        #expect(!browse.complete(settlement, finished: true))
        #expect(browse.state.selected == .conversation("c1"))
        #expect(browse.state.phase == .idle && browse.summaries == before)
        #expect(browse.errorMessage != nil)
    }
}
