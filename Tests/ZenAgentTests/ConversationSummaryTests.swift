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

    @Test("browse neighborhoods use nearest inverse keyset across 100 real histories")
    func browseNeighborhoodsAreBounded() throws {
        let fixture = try seed(historyCount: 100)
        let trace = S504SQLTrace()
        try fixture.store.database.read { db in
            db.trace { if case .statement(let statement) = $0 { trace.record(statement.sql) } }
        }
        defer { try? fixture.store.database.read { db in db.trace(nil) } }
        for index in [0, 1, 7, 8, 49, 96, 99] {
            let id = fixture.orderedIDs[index]
            let window = try fixture.store.conversationBrowseWindow(id: id)
            #expect(window.current?.id == id)
            #expect(window.older.map(\.id) == Array(fixture.orderedIDs.dropFirst(index + 1).prefix(3)))
            #expect(window.newer?.id == (index == 0 ? nil : fixture.orderedIDs[index - 1]))
            #expect(window.summaries.count <= 5)
            #expect(Set(window.summaries.map(\.id)).count == window.summaries.count)
            #expect(window.summaries.allSatisfy { $0.excerpt.count <= 320 })
        }
        // Each window reads one current, at most three older and one newer.
        // Extra-row keyset lookahead is metadata-bounded and never a full history read.
        #expect(trace.summaryQueryCount <= 21)
        #expect(try fixture.store.conversationBrowseWindow(id: "uncommitted").current == nil)
        #expect(throws: (any Error).self) { try fixture.store.conversationBrowseWindow(id: "hidden") }
    }

    @Test("100-step actual history browse keeps only five projections and preserves selection on SQL failure")
    @MainActor
    func browseControllerDoesNotAccumulateHistory() throws {
        let fixture = try seed(historyCount: 100)
        let browse = AppSpaceBrowseController(reader: { try fixture.store.conversationBrowseWindow(id: $0) })
        browse.present(originID: fixture.orderedIDs[0])
        for index in 1..<100 {
            #expect(browse.begin())
            #expect(browse.drag(displacement: 200, travel: 300))
            let settlement = try #require(browse.end(velocity: 100_000, travel: 300))
            #expect(browse.complete(settlement, finished: true))
            #expect(browse.state.selected == .conversation(fixture.orderedIDs[index]))
            #expect(browse.summaries.count <= 5)
            #expect(browse.currentSummary?.id == fixture.orderedIDs[index])
        }
        let previous = browse.summaries
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE message RENAME TO unavailable_browse_message") }
        #expect(browse.begin())
        #expect(browse.drag(displacement: -200, travel: 300))
        let failed = try #require(browse.end(velocity: 0, travel: 300))
        #expect(!browse.complete(failed, finished: true))
        #expect(browse.state.selected == .conversation(fixture.orderedIDs[99]))
        #expect(browse.summaries == previous && browse.errorMessage != nil)
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE unavailable_browse_message RENAME TO message") }
        browse.refresh()
        #expect(browse.errorMessage == nil)
        #expect(browse.begin())
        #expect(browse.drag(displacement: -200, travel: 300))
        let cancelled = try #require(browse.end(velocity: 0, travel: 300))
        browse.cancel()
        #expect(!browse.complete(cancelled, finished: true))
        #expect(browse.currentSummary?.id == fixture.orderedIDs[99])
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

    @Test("unknown Run metadata isolates one summary without losing page or window identity",
          arguments: ["state", "endReason"])
    func unknownRunMetadataIsLocal(column: String) throws {
        let fixture = try seed(historyCount: 52)
        let before = try fixture.store.conversationSummaryPage()
        let badID = fixture.orderedIDs[1]
        let badBefore = try #require(before.items.first { $0.id == badID })
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET \(column) = ? WHERE id = ?",
                arguments: ["unknown-test-only-value", "run-\(badID)"])
        }
        let page = try fixture.store.conversationSummaryPage()
        #expect(page.items.map(\.id) == before.items.map(\.id))
        #expect(page.nextCursor == before.nextCursor)
        let bad = try #require(page.items.first { $0.id == badID })
        #expect(bad.title == badBefore.title && bad.excerpt == badBefore.excerpt && bad.cursor == badBefore.cursor)
        #expect(bad.contentUnavailable)
        #expect(bad.runProjection == nil)
        #expect(page.items.filter { $0.id != badID } == before.items.filter { $0.id != badID })
        let cursor = try #require(page.nextCursor)
        let next = try fixture.store.conversationSummaryPage(after: cursor)
        #expect(next.items.map(\.id) == Array(fixture.orderedIDs.dropFirst(50)))
        let ids = Array(fixture.orderedIDs.prefix(4))
        let window = try fixture.store.conversationSummaryWindow(ids: ids)
        #expect(window.map(\.id) == ids)
        #expect(window.first { $0.id == badID }?.contentUnavailable == true)
        #expect(window.filter { $0.id != badID }.allSatisfy { $0.runProjection?.state == .completed })
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
