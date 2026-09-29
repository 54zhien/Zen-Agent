import Foundation
import Testing
import UIKit

@testable import ZenAgent

private enum CardReplacementReadError: Error { case injected }

@Suite("App Space selection after Card Delete")
@MainActor
struct AppSpaceCardDeletionSelectionTests {
    @Test("failed replacement reads never leave a deleted Current selected")
    func failedReplacementKeepsBrowseCoherent() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "only", at: Fixtures.epoch)
        var failReads = false
        let browse = AppSpaceBrowseController(reader: { id in
            if failReads { throw CardReplacementReadError.injected }
            return try store.conversationBrowseWindow(id: id)
        })
        browse.configureNewEntry(reader: {
            if failReads { throw CardReplacementReadError.injected }
            return try store.conversationNewBrowseWindow(originID: "only")
        })
        browse.present(originID: "only")
        browse.beginDeletionReplacement(id: "only")
        browse.advanceDeletionReplacement()
        _ = try store.beginCardDeletion(conversationID: "only", at: Fixtures.epoch)
        failReads = true

        #expect(!browse.selectAfterDeleting(id: "only"))
        #expect(browse.selectedConversationID != "only")
        #expect(browse.deletionTarget == nil)
        #expect(browse.deletionProgress == 0)
        #expect(browse.errorMessage != nil)

        failReads = false
        browse.refresh()
        #expect(browse.isNewEntry)
        #expect(browse.selectedConversationID == nil)
    }

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
        browse.updateViewport(size: CGSize(width: 400, height: 800),
            safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        let before = try #require(browse.layout())
        let current = try #require(before.cards.first { $0.item == .conversation("c2") })
        let predecessor = try #require(before.cards.first { $0.item == .conversation("c1") })
        browse.beginDeletionReplacement(id: "c2")
        browse.advanceDeletionReplacement()
        let promoted = browse.deletionProjection(predecessor, in: before)
        #expect(promoted.frame == current.frame)
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
