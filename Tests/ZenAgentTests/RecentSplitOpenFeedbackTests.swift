import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Recent occupied Split open feedback")
@MainActor
struct RecentSplitOpenFeedbackTests {
    @Test("occupied secondary failure preserves both owners and retries the same target")
    func occupiedSecondaryRecentOpenFailureKeepsPaneAndTargetsRetry() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "recent-secondary-B").insert(db)
        }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "recent-target-C", messageID: "recent-C-user", runID: "recent-C-run", runState: .completed))
        let model = fixture.model
        let source = try #require(model.pane)
        #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
        #expect(await model.openInSplit(id: "recent-secondary-B"))
        let secondary = try #require(model.splitPane)
        secondary.composer.draft.text = "B retained draft"
        secondary.composer.draft.selection = ComposerSelection(range: 2..<5)
        let arrangement = try #require(model.splitWorkspace)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                arguments: ["invalid-recent-C-state", "recent-C-run"])
        }
        model.refreshRecentConversations()
        #expect(model.recentConversations.contains { $0.id == "recent-target-C" })
        #expect(!(await model.openInSplit(id: "recent-target-C")))
        #expect(model.pane === source)
        #expect(model.splitPane === secondary)
        #expect(model.splitPane?.session === secondary.session)
        #expect(secondary.composer.draft.text == "B retained draft")
        #expect(secondary.composer.draft.selection == ComposerSelection(range: 2..<5))
        #expect(model.splitWorkspace == arrangement)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                arguments: [RunState.completed.rawValue, "recent-C-run"])
        }
        #expect(await model.openInSplit(id: "recent-target-C"))
        #expect(model.splitPane?.conversationID == "recent-target-C")
        #expect(model.pane === source)
        #expect(secondary.composer.draft.text == "B retained draft")
    }
}
