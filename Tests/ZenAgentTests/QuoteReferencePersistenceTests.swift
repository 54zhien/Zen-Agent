import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Quote reference persistence")
struct QuoteReferencePersistenceTests {
    @Test("v9 quote cascade follows the target message only")
    func v9QuoteCascadeFollowsTargetOnly() throws {
        let store = try makeStore()
        try insertSource(in: store)
        var commit = Fixtures.send(messageID: "target-message", runID: "target-run")
        commit.quoteReferences = [record(messageID: "target-message", sequence: 0)]
        try store.commitUserTurnAndCreateParentRun(commit)

        try store.database.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["source-message"])
        }
        let surviving = try store.quoteReferences(forMessageID: "target-message")
        #expect(surviving.map(\.snapshot) == ["quoted snapshot"])
        #expect(try store.quoteSourceIsAvailable(surviving[0]) == false)

        try store.database.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["target-message"])
        }
        #expect(try store.quoteReferences(forMessageID: "target-message").isEmpty)
    }

    @Test("v9 quote sequence and range constraints reject invalid rows")
    func v9QuoteSequenceAndRangeConstraintsRejectInvalidRows() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "target-message", runID: "target-run")
        )

        for invalid in [
            (id: "negative-sequence", sequence: -1, sourcePart: "part-a", start: 0, length: 1),
            (id: "negative-start", sequence: 0, sourcePart: "part-b", start: -1, length: 1),
            (id: "zero-length", sequence: 0, sourcePart: "part-c", start: 0, length: 0),
        ] {
            var rejected = false
            do {
                try insertRaw(
                    invalid.id,
                    in: store,
                    sequence: invalid.sequence,
                    sourcePartID: invalid.sourcePart,
                    start: invalid.start,
                    length: invalid.length
                )
            } catch {
                rejected = true
            }
            #expect(rejected)
        }

        try insertRaw("valid", in: store, sequence: 0, sourcePartID: "part-valid", start: 0, length: 1)
        var duplicateSequenceRejected = false
        do {
            try insertRaw("duplicate-sequence", in: store, sequence: 0, sourcePartID: "part-other", start: 1, length: 1)
        } catch {
            duplicateSequenceRejected = true
        }
        #expect(duplicateSequenceRejected)

        var duplicateRangeRejected = false
        do {
            try insertRaw("duplicate-range", in: store, sequence: 1, sourcePartID: "part-valid", start: 0, length: 1)
        } catch {
            duplicateRangeRejected = true
        }
        #expect(duplicateRangeRejected)
    }

    @Test("a committed quote snapshot survives source deletion")
    func committedQuoteSnapshotSurvivesSourceDeletion() throws {
        let store = try makeStore()
        try insertSource(in: store)
        var commit = Fixtures.send(messageID: "target-message", runID: "target-run")
        commit.quoteReferences = [record(messageID: "target-message", sequence: 0)]
        try store.commitUserTurnAndCreateParentRun(commit)

        try store.database.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["source-conversation"])
        }

        let references = try store.quoteReferences(forMessageID: "target-message")
        #expect(references.count == 1)
        #expect(references[0].snapshot == "quoted snapshot")
        #expect(references[0].sourceConversationID == "source-conversation")
        #expect(try store.quoteSourceIsAvailable(references[0]) == false)
    }

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func insertSource(in store: PersistenceStore) throws {
        try store.database.write { db in
            try Fixtures.conversation(id: "source-conversation").insert(db)
            try Fixtures.message(id: "source-message", conversationID: "source-conversation").insert(db)
            try MessagePartRecord(
                id: "source-part",
                messageID: "source-message",
                sequence: 0,
                kind: .text,
                state: .completed,
                payload: try PersistenceStore.encodeTextPayload(.init(text: "quoted snapshot"))
            ).insert(db)
        }
    }

    private func record(messageID: String, sequence: Int) -> MessageQuoteReferenceRecord {
        MessageQuoteReferenceRecord(
            id: "quote-\(messageID)-\(sequence)",
            messageID: messageID,
            sequence: sequence,
            sourceConversationID: "source-conversation",
            sourceMessageID: "source-message",
            sourcePartID: "source-part",
            sourceUTF16Start: 0,
            sourceUTF16Length: 15,
            snapshot: "quoted snapshot",
            createdAt: Fixtures.epoch
        )
    }

    private func insertRaw(
        _ id: String,
        in store: PersistenceStore,
        sequence: Int,
        sourcePartID: String,
        start: Int,
        length: Int
    ) throws {
        try store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messageQuoteReference
                        (id, messageID, sequence, sourceConversationID, sourceMessageID, sourcePartID,
                         sourceUTF16Start, sourceUTF16Length, snapshot, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, "target-message", sequence, "source-conversation", "source-message",
                    sourcePartID, start, length, "snapshot", Fixtures.epoch,
                ]
            )
        }
    }
}
