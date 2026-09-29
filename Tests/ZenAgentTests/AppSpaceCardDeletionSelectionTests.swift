import Foundation
import Testing

@testable import ZenAgent

@Suite("App Space selection after Card Delete")
@MainActor
struct AppSpaceCardDeletionSelectionTests {
    @Test("deleted Current reveals its nearest predecessor in a bounded window")
    func predecessorBecomesCurrent() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        for (index, id) in ["c1", "c2", "c3"].enumerated() {
            try store.createEmptyConversation(id: id,
                at: Fixtures.epoch.addingTimeInterval(TimeInterval(index)))
        }
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: { try store.conversationNewBrowseWindow(originID: "c2") })
        browse.present(originID: "c2")
        #expect(browse.selectedConversationID == "c2")

        _ = try store.beginCardDeletion(conversationID: "c2", at: Fixtures.epoch.addingTimeInterval(4))
        #expect(browse.selectAfterDeleting(id: "c2"))
        #expect(browse.selectedConversationID == "c1")
        #expect(browse.currentSummary?.id == "c1")
        #expect(browse.summaries.count <= 5)
        #expect(!browse.summaries.map(\.id).contains("c2"))
    }

    @Test("deleting the only committed Current lands on New")
    func lastCardBecomesNew() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "only", at: Fixtures.epoch)
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: { try store.conversationNewBrowseWindow(originID: "only") })
        browse.present(originID: "only")
        _ = try store.beginCardDeletion(conversationID: "only", at: Fixtures.epoch)
        #expect(browse.selectAfterDeleting(id: "only"))
        #expect(browse.isNewEntry)
        #expect(browse.selectedConversationID == nil)
    }
}
