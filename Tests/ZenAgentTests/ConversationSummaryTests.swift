import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Bounded conversation summaries")
struct ConversationSummaryTests {
    private struct SeededHistory {
        let store: PersistenceStore
        let orderedIDs: [String]
    }

    private static func id(_ index: Int) -> String { String(format: "summary-%04d", index) }

    private func seed(historyCount: Int) throws -> SeededHistory {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createProviderInstance(ProviderInstance(id: ProviderInstanceID(rawValue: "pi1"),
            providerID: .deepSeek, displayName: "Summary provider", baseURL: nil,
            configRevision: .initial, credentialReference: nil))
        let rows = (0..<historyCount).map { index -> ConversationRecord in
            var row = Fixtures.conversation(id: Self.id(index), title: "")
            row.pinned = index % 13 == 0
            row.userActiveAt = Fixtures.epoch.addingTimeInterval(Double(index % 7))
            return row
        }
        try store.database.write { db in
            for (index, row) in rows.enumerated() {
                try row.insert(db)
                let userID = "user-\(row.id)"
                let assistantID = "assistant-\(row.id)"
                try Fixtures.message(id: userID, conversationID: row.id).insert(db)
                try Fixtures.message(id: assistantID, conversationID: row.id,
                    role: .assistant, sequence: 1).insert(db)
                var user = Fixtures.textPart(id: "user-part-\(row.id)", messageID: userID)
                user.payload = try PersistenceStore.encodeTextPayload(.init(text: "  prompt \(index)  "))
                try user.insert(db)
                var answer = Fixtures.textPart(id: "assistant-part-\(row.id)", messageID: assistantID)
                answer.payload = try PersistenceStore.encodeTextPayload(.init(
                    text: "answer \(index) " + String(repeating: "正文", count: 5_000)))
                try answer.insert(db)
                try Fixtures.run(id: "run-\(row.id)", conversationID: row.id, state: .completed,
                    endReason: .completed, triggerMessageID: userID, responseMessageID: assistantID).insert(db)
            }
            try Fixtures.conversation(id: "hidden", lifecycle: .pendingDeletion).insert(db)
        }
        let ordered = rows.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned }
            if left.userActiveAt != right.userActiveAt { return left.userActiveAt > right.userActiveAt }
            return left.id < right.id
        }
        return SeededHistory(store: store, orderedIDs: ordered.map(\.id))
    }

    @Test("keyset pages preserve pinned activity and tie order without whole-history payloads",
          arguments: [100, 1_000])
    func pagesAreBounded(historyCount: Int) throws {
        let fixture = try seed(historyCount: historyCount)
        let trace = S504SQLTrace()
        try fixture.store.database.read { db in
            db.trace { if case .statement(let statement) = $0 { trace.record(statement.sql) } }
        }
        let clock = ContinuousClock()
        let begin = clock.now
        let page = try fixture.store.conversationSummaryPage(limit: 50)
        let elapsed = begin.duration(to: clock.now)
        try fixture.store.database.read { db in db.trace(nil) }
        #expect(page.items.count == 50)
        #expect(trace.selectCount <= 2)
        #expect(page.items.prefix(50).map(\.id) == Array(fixture.orderedIDs.prefix(50)))
        #expect(page.items.allSatisfy { !$0.title.isEmpty && $0.title.count <= 56 })
        #expect(page.items.allSatisfy { $0.excerpt.count <= 320 })
        let first = try #require(page.items.first)
        #expect(first.providerInstanceID == ProviderInstanceID(rawValue: "pi1"))
        #expect(first.modelID == ModelID(rawValue: "deepseek-chat"))
        #expect(first.providerName == "Summary provider")
        #expect(first.runProjection?.state == .completed)
        #expect(first.excerpt.hasPrefix("answer "))
        print("S504 summary rows=\(historyCount) returned=\(page.items.count) SELECTs=\(trace.selectCount) elapsed=\(elapsed)")

        var seen = page.items.map(\.id)
        var cursor = try #require(page.nextCursor)
        for _ in 0..<100 {
            let next = try fixture.store.conversationSummaryPage(limit: 50, after: cursor)
            #expect(next.items.count <= 50)
            seen.append(contentsOf: next.items.map(\.id))
            guard let following = next.nextCursor else { break }
            #expect(following != cursor)
            cursor = following
        }
        #expect(seen == fixture.orderedIDs)
        #expect(Set(seen).count == historyCount)
        #expect(try fixture.store.conversation(id: first.id)?.userActiveAt == first.userActiveAt)
    }

    @Test("a preview window is finite and preserves caller identities")
    func windowIsBounded() throws {
        let fixture = try seed(historyCount: 10)
        let ids = [7, 2, 9, 4, 6].map(Self.id)
        let window = try fixture.store.conversationSummaryWindow(ids: ids)
        #expect(window.map(\.id) == Array(ids.prefix(4)))
        let sparse = try fixture.store.conversationSummaryWindow(ids: [Self.id(3), "missing", "hidden", Self.id(3)])
        #expect(sparse.map(\.id) == [Self.id(3)])
        #expect(try fixture.store.conversationSummaryWindow(ids: []).isEmpty)
    }

    @Test("a newer Child Run cannot replace its Parent in the card summary")
    func latestParentOwnsSummary() throws {
        let fixture = try seed(historyCount: 1)
        let id = Self.id(0)
        try fixture.store.database.write { db in
            try Fixtures.run(id: "newer-child", conversationID: id, kind: .child,
                state: .failed, endReason: .providerFailed, parentRunID: "run-\(id)",
                createdAt: Fixtures.epoch.addingTimeInterval(1)).insert(db)
        }
        let summary = try #require(try fixture.store.conversationSummaryPage().items.first)
        #expect(summary.runProjection?.runID == "run-\(id)")
        #expect(summary.runProjection?.state == .completed)
        #expect(summary.runProjection?.endReason == .completed)
    }

    @Test("page size is an engineering bound even for extreme caller inputs")
    func pageSizeIsClamped() throws {
        let fixture = try seed(historyCount: 100)
        #expect(try fixture.store.conversationSummaryPage(limit: Int.max).items.count == 50)
        #expect(try fixture.store.conversationSummaryPage(limit: 0).items.count == 1)
        #expect(try fixture.store.conversationSummaryPage(limit: -1).items.count == 1)
    }

    @Test("summary read errors throw instead of impersonating empty history")
    func missingTableThrows() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in try db.execute(sql: "DROP TABLE conversation") }
        #expect(throws: DatabaseError.self) { try store.conversationSummaryPage() }
    }

    @Test("malformed text has an explicit unavailable outcome and never discloses other Part kinds",
          arguments: ["{broken", #"{"notText":42}"#, #"{"text":42}"#])
    func corruptPayloadAndDisclosure(payload: String) throws {
        let fixture = try seed(historyCount: 1)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE messagePart SET payload = ? WHERE id = ?",
                arguments: [payload, "assistant-part-\(Self.id(0))"])
            var hidden = Fixtures.textPart(id: "reasoning-secret", messageID: "assistant-\(Self.id(0))",
                sequence: 1, text: "FORBIDDEN_REASONING_DETAIL")
            hidden.kind = .reasoning
            try hidden.insert(db)
        }
        let summary = try #require(try fixture.store.conversationSummaryPage().items.first)
        #expect(summary.contentUnavailable)
        #expect(!summary.excerpt.contains("FORBIDDEN_REASONING_DETAIL"))
        #expect(!summary.excerpt.contains("cred-1"))
        #expect(summary.title == "prompt 0")
    }
}
