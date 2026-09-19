import Foundation
import Testing

import GRDB
import SwiftData

/// Stage 0 wiring checks for the persistence spike.
///
/// These do NOT implement the seven spike scenarios (see README.md in this
/// directory for those). They answer the narrower question that has to be
/// answered first: **can both candidate engines even be built and driven from
/// this test target in CI?** If this file fails, nothing above it is worth
/// debugging.
///
/// One mechanism is probed early because it decides scenario B outright: the
/// blueprint requires "at most one *non-terminal* Parent Run per Conversation".
/// That is a *conditional* uniqueness constraint, and neither engine has a
/// first-class API for it. The standard relational workaround is a nullable
/// "active slot" column — equal to the conversation id while the run is active,
/// NULL once it reaches a terminal state — combined with a unique index, because
/// SQL treats NULLs as distinct and therefore permits many terminal rows.
@Suite("Persistence engine wiring")
struct EngineWiringTests {

    // MARK: - GRDB

    @Test("GRDB opens an in-memory database and round-trips a row")
    func grdbRoundTrip() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "probe") { t in
                t.primaryKey("id", .text)
                t.column("value", .text).notNull()
            }
            try db.execute(
                sql: "INSERT INTO probe (id, value) VALUES (?, ?)",
                arguments: ["a", "hello"]
            )
        }

        let value = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM probe WHERE id = ?", arguments: ["a"])
        }

        #expect(value == "hello")
    }

    @Test("GRDB can express conditional uniqueness via a partial unique index")
    func grdbConditionalUniqueness() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "run") { t in
                t.primaryKey("id", .text)
                t.column("conversationID", .text).notNull()
                // NULL while the run is active-or-not is decided by this column:
                // equal to conversationID while active, NULL once terminal.
                t.column("activeSlot", .text)
            }
            // Partial index: only rows with a non-NULL slot participate.
            try db.execute(sql: """
                CREATE UNIQUE INDEX run_one_active_per_conversation
                ON run (activeSlot)
                WHERE activeSlot IS NOT NULL
                """)

            try db.execute(sql: "INSERT INTO run (id, conversationID, activeSlot) VALUES ('r1', 'c1', 'c1')")
        }

        // A second active run in the same conversation must be rejected.
        var secondActiveRejected = false
        do {
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO run (id, conversationID, activeSlot) VALUES ('r2', 'c1', 'c1')")
            }
        } catch {
            secondActiveRejected = true
        }
        #expect(secondActiveRejected, "a second active run in the same conversation must not be insertable")

        // Retiring the first run must free the slot, and many terminal runs must coexist.
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE run SET activeSlot = NULL WHERE id = 'r1'")
            try db.execute(sql: "INSERT INTO run (id, conversationID, activeSlot) VALUES ('r2', 'c1', 'c1')")
            try db.execute(sql: "UPDATE run SET activeSlot = NULL WHERE id = 'r2'")
            try db.execute(sql: "INSERT INTO run (id, conversationID, activeSlot) VALUES ('r3', 'c1', NULL)")
            try db.execute(sql: "INSERT INTO run (id, conversationID, activeSlot) VALUES ('r4', 'c1', NULL)")
        }

        let total = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run") ?? -1
        }
        #expect(total == 4, "terminal runs must not compete for the active slot")
    }

    // MARK: - SwiftData

    @Test("SwiftData builds an in-memory container and round-trips a row")
    @MainActor
    func swiftDataRoundTrip() throws {
        let container = try ModelContainer(
            for: SpikeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        context.insert(SpikeRecord(slot: nil, value: "hello"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SpikeRecord>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.value == "hello")
    }

    @Test("SwiftData unique constraint permits multiple NULL slots")
    @MainActor
    func swiftDataNullableUniqueness() throws {
        let container = try ModelContainer(
            for: SpikeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // Two terminal runs: both slots NULL. If SQL's "NULLs are distinct" rule
        // does not hold through SwiftData's uniqueness machinery, this save fails
        // and scenario B has no viable SwiftData implementation.
        context.insert(SpikeRecord(slot: nil, value: "terminal-1"))
        context.insert(SpikeRecord(slot: nil, value: "terminal-2"))
        try context.save()

        let count = try context.fetchCount(FetchDescriptor<SpikeRecord>())
        #expect(count == 2, "multiple terminal (NULL-slot) rows must coexist")

        // One active run occupies the slot...
        context.insert(SpikeRecord(slot: "c1", value: "active-1"))
        try context.save()

        // ...and a second one must be rejected.
        context.insert(SpikeRecord(slot: "c1", value: "active-2"))
        var duplicateActiveRejected = false
        do {
            try context.save()
        } catch {
            duplicateActiveRejected = true
        }
        #expect(duplicateActiveRejected, "a second active run in the same conversation must not be insertable")
    }
}

// MARK: - Probe model

/// Throwaway model for wiring checks only. Not a draft of any product entity.
///
/// `slot` is the nullable active-slot described above: the conversation id while
/// the run is active, `nil` once terminal.
@Model
final class SpikeRecord {
    #Unique<SpikeRecord>([\.slot])

    var slot: String?
    var value: String

    init(slot: String?, value: String) {
        self.slot = slot
        self.value = value
    }
}
