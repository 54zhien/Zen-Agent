import Foundation
import Testing
@testable import ZenAgent

@Suite("App Space Rename title")
@MainActor
struct AppSpaceRenameTitleTests {
    @Test(arguments: ["provisional", "empty", "whitespace", "manual", "deleted"])
    func prefillMatchesTheDisplayedFallbackAndPreservesFullManualTitle(kind: String) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let stored = kind == "manual" ? String(repeating: "手动标题", count: 30)
            : kind == "whitespace" ? " \u{3000}\n" : ""
        try store.database.write { db in
            try Fixtures.conversation(id: "rename", title: stored,
                lifecycle: kind == "deleted" ? .pendingDeletion : .visible).insert(db)
            if kind == "provisional" {
                try Fixtures.message(id: "prompt", conversationID: "rename").insert(db)
                var part = Fixtures.textPart(id: "text", messageID: "prompt")
                part.payload = try PersistenceStore.encodeTextPayload(.init(
                    text: "  我的\u{3000}计划\n" + String(repeating: "🧑🏽‍💻", count: 70)))
                try part.insert(db)
            }
        }
        let displayed = try store.conversationSummaryWindow(ids: ["rename"]).first?.title
        let actions = AppSpaceConversationActions(store: store)
        #expect(actions.title(id: "rename") == (kind == "manual" ? stored : displayed))
        #expect(try store.conversation(id: "rename")?.title == stored)
        #expect(actions.title(id: "missing") == nil)
    }
}
