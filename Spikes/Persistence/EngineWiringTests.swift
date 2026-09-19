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

    @Test("SwiftData permits multiple NULL slots")
    @MainActor
    func swiftDataNullableSlotsCoexist() throws {
        let container = try ModelContainer(
            for: SpikeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // Two terminal runs: both slots NULL. If SQL's "NULLs are distinct" rule
        // does not hold through SwiftData's uniqueness machinery, this save fails
        // and the nullable-slot workaround has no viable SwiftData implementation.
        context.insert(SpikeRecord(slot: nil, value: "terminal-1"))
        context.insert(SpikeRecord(slot: nil, value: "terminal-2"))
        try context.save()

        let count = try context.fetchCount(FetchDescriptor<SpikeRecord>())
        #expect(count == 2, "multiple terminal (NULL-slot) rows must coexist")
    }

    // MARK: Experiment — what does SwiftData actually do on an occupied slot?

    /// Scenario B needs "at most one *non-terminal* Parent Run per Conversation".
    /// That means a second writer must **fail cleanly**. Three outcomes are
    /// possible and only the first is acceptable; the other two are materially
    /// different problems, so this test reports which one occurred rather than
    /// just asserting a boolean.
    ///
    /// 1. `REJECTED` — save throws. The invariant is expressible.
    /// 2. `DUPLICATE ACCEPTED` — the constraint is not enforced at all.
    /// 3. `SILENT REPLACEMENT` — the first active run was overwritten. Worse than
    ///    (2), because the lost run is an *active* one and nothing reports an error.
    ///
    /// This deliberately asserts the requirement rather than the observation: a red
    /// result here is a real finding about the engine, and the failure message
    /// carries the evidence needed to design around it.
    @Test("SwiftData: an occupied unique slot — rejected, duplicated, or silently replaced?")
    @MainActor
    func swiftDataOccupiedSlotSemantics() throws {
        let container = try ModelContainer(
            for: SpikeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        context.insert(SpikeRecord(slot: "c1", value: "active-1"))
        try context.save()

        context.insert(SpikeRecord(slot: "c1", value: "active-2"))
        var threw = false
        do {
            try context.save()
        } catch {
            threw = true
        }

        let rows = try context.fetch(FetchDescriptor<SpikeRecord>())
        let dumped = rows
            .map { "\($0.value)/slot=\($0.slot ?? "nil")" }
            .sorted()
            .joined(separator: ", ")

        let outcome: String
        if threw {
            outcome = "REJECTED (save threw)"
        } else if rows.count == 1 {
            outcome = "SILENT REPLACEMENT (upsert — the first active run was overwritten)"
        } else {
            outcome = "DUPLICATE ACCEPTED (constraint not enforced)"
        }

        #expect(threw, "expected REJECTED; observed \(outcome). rows after save: [\(dumped)]")
    }

    /// Second hypothesis, same experiment. If the optional `slot` is what defeats
    /// the constraint, a **non-optional** slot should reject properly.
    ///
    /// This matters because a non-optional slot is a better design anyway: the
    /// column holds the conversation id while active and a per-run unique value
    /// once terminal, so uniqueness is unconditional and both engines express it
    /// the same way — no reliance on SQL's NULL-is-distinct rule at all.
    ///
    /// - Non-optional rejects → the problem was the optional attribute, and the
    ///   sentinel design is the workaround.
    /// - Non-optional also does not reject → SwiftData upserts on unique conflicts
    ///   generally, and no column shape will rescue scenario B.
    @Test("SwiftData: non-optional unique slot — does it reject a second occupant?")
    @MainActor
    func swiftDataNonNullSentinelSemantics() throws {
        let container = try ModelContainer(
            for: SentinelRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // Terminal runs carry a per-run key, so they never collide with each other.
        context.insert(SentinelRecord(slot: "run-t1", value: "terminal-1"))
        context.insert(SentinelRecord(slot: "run-t2", value: "terminal-2"))
        try context.save()
        #expect(
            try context.fetchCount(FetchDescriptor<SentinelRecord>()) == 2,
            "distinct terminal keys must coexist"
        )

        context.insert(SentinelRecord(slot: "c1", value: "active-1"))
        try context.save()

        context.insert(SentinelRecord(slot: "c1", value: "active-2"))
        var threw = false
        do {
            try context.save()
        } catch {
            threw = true
        }

        let rows = try context.fetch(FetchDescriptor<SentinelRecord>())
            .filter { $0.slot == "c1" }
        let dumped = rows.map(\.value).sorted().joined(separator: ", ")

        let outcome: String
        if threw {
            outcome = "REJECTED"
        } else if rows.count == 1 {
            outcome = "SILENT REPLACEMENT (upsert)"
        } else {
            outcome = "DUPLICATE ACCEPTED"
        }

        #expect(threw, "expected REJECTED with a non-optional slot; observed \(outcome). rows for slot c1: [\(dumped)]")
    }
}

// MARK: - Probe models

/// Throwaway models for wiring checks only. Not drafts of any product entity.

/// Nullable active-slot: the conversation id while the run is active, `nil` once
/// terminal. Relies on SQL treating NULLs as distinct so terminal rows coexist.
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

/// Non-optional active-slot: the conversation id while active, a per-run unique
/// value once terminal. Uniqueness is unconditional, so it does not depend on any
/// engine's NULL handling.
@Model
final class SentinelRecord {
    #Unique<SentinelRecord>([\.slot])

    var slot: String
    var value: String

    init(slot: String, value: String) {
        self.slot = slot
        self.value = value
    }
}
