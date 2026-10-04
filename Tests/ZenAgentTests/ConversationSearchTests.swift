import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Conversation title Search")
struct ConversationSearchTests {
    @Test("Search matches the displayed title literally, including SQL pattern characters")
    func literalTitleMatching() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            try Fixtures.conversation(id: "literal", title: "设计 100% a_b a\\b 'quote'; --").insert(db)
            try Fixtures.conversation(id: "decoy", title: "Design 1000 axb ab").insert(db)
            try Fixtures.conversation(id: "ascii", title: "Mixed CASE Title").insert(db)
        }
        for query in ["设计", "100%", "a_b", "a\\b", "'quote'", "; --"] {
            let page = try store.searchConversationSummaries(query: query, limit: 50)
            #expect(page.items.map(\.id) == ["literal"])
        }
        #expect(try store.searchConversationSummaries(query: "mixed case", limit: 50).items.map(\.id) == ["ascii"])
        #expect(try store.searchConversationSummaries(query: "' OR 1=1 --", limit: 50).items.isEmpty)
        #expect(try store.searchConversationSummaries(query: " \n\u{3000} ", limit: 50).items.isEmpty)
    }

    @Test("fallback Search uses the bounded displayed provisional title and respects manual Rename")
    func provisionalTitleIsNotBodySearch() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            for id in ["fallback", "manual"] {
                try Fixtures.conversation(id: id, title: id == "manual" ? "Manual chosen name" : "").insert(db)
                try Fixtures.message(id: "message-\(id)", conversationID: id).insert(db)
                var part = Fixtures.textPart(id: "part-\(id)", messageID: "message-\(id)")
                part.payload = try PersistenceStore.encodeTextPayload(.init(text:
                    "  Unicode\u{3000}whitespace \n" + String(repeating: "A", count: 60) + " body-only-needle"))
                try part.insert(db)
            }
        }
        let page = try store.searchConversationSummaries(query: "Unicode whitespace", limit: 50)
        #expect(page.items.map(\.id) == ["fallback"])
        let displayed = try store.conversationSummaryWindow(ids: ["fallback"]).first?.title
        #expect(page.items.first?.title == displayed)
        #expect(page.items.first?.title.count == 56)
        #expect(try store.searchConversationSummaries(query: "body-only-needle", limit: 50).items.isEmpty)
        #expect(try store.searchConversationSummaries(query: "Manual chosen", limit: 50).items.map(\.id) == ["manual"])
    }

    @Test("Search pages use stable pinned activity keysets and exclude both deletion lifecycles")
    func pagesRemainBoundedAndVisible() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let rows = (0..<120).map { index -> ConversationRecord in
            var row = Fixtures.conversation(id: String(format: "search-%03d", index), title: "paging result \(index)")
            row.pinned = index % 9 == 0
            row.userActiveAt = Fixtures.epoch.addingTimeInterval(Double(index % 5))
            return row
        }
        try store.database.write { db in
            for row in rows { try row.insert(db) }
            try Fixtures.conversation(id: "pending", title: "paging pending", lifecycle: .pendingDeletion).insert(db)
            try Fixtures.conversation(id: "deleted", title: "paging deleted", lifecycle: .finalizedDeletion).insert(db)
        }
        let expected = rows.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.userActiveAt != rhs.userActiveAt { return lhs.userActiveAt > rhs.userActiveAt }
            return lhs.id < rhs.id
        }.map(\.id)
        var all: [String] = []
        var cursor: ConversationSummaryCursor?
        repeat {
            let page = try store.searchConversationSummaries(query: "paging", limit: 500, after: cursor)
            #expect(page.items.count <= 50)
            all.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        #expect(all == expected)
        #expect(Set(all).count == rows.count)
    }

    @Test("Whitespace parts are skipped but malformed first text keeps the displayed fallback")
    func unavailableFirstPartDoesNotExposeLaterBodyText() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            try Fixtures.conversation(id: "parts", title: "").insert(db)
            try Fixtures.message(id: "message", conversationID: "parts").insert(db)
            let payloads = [try PersistenceStore.encodeTextPayload(.init(text: " \u{3000} ")),
                "malformed", try PersistenceStore.encodeTextPayload(.init(text: "later body secret"))]
            for (index, payload) in payloads.enumerated() {
                var part = Fixtures.textPart(id: "part-\(index)", messageID: "message")
                part.sequence = index
                part.payload = payload
                try part.insert(db)
            }
        }
        let shown = try #require(store.conversationSummaryWindow(ids: ["parts"]).first)
        #expect(shown.title == "未命名会话")
        #expect(shown.contentUnavailable)
        #expect(try store.searchConversationSummaries(query: "未命名", limit: 50).items.first?.title == shown.title)
        #expect(try store.searchConversationSummaries(query: "later body", limit: 50).items.isEmpty)
    }
}
