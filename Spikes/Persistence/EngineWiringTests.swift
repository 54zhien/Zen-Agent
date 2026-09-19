import Foundation
import Testing

import GRDB
import SwiftData

/// Stage 0 wiring checks for the persistence spike.
///
/// These do NOT implement the seven spike scenarios (see README.md in this
/// directory for those). Two suites live here for different purposes:
///
/// - **Persistence engine wiring** — can both engines be built and driven from
///   this target in CI, and what are their declared-constraint semantics? These
///   pass; a failure means the infrastructure broke, not that an engine lost.
/// - **Scenario B probe** — the decisive experiment for the one invariant that
///   separates the candidates.
///
/// ## What the first CI runs established
///
/// The blueprint requires "at most one *non-terminal* Parent Run per
/// Conversation" — a **conditional** uniqueness constraint that neither engine
/// expresses first-class. Both candidates were probed with the natural relational
/// workaround (a slot column that is set while the run is active and released
/// once terminal, plus a unique index):
///
/// - **GRDB rejects correctly.** A partial unique index refuses the second
///   occupant, and multiple terminal rows coexist.
/// - **SwiftData silently overwrites.** `#Unique` has upsert semantics: the
///   second writer *replaces* the first, with no error raised. Making the slot
///   non-optional does not change this. For an exclusivity invariant that is
///   worse than having no constraint at all — the constraint destroys the very
///   row it is supposed to protect.
///
/// That result rules out *one mechanism*, not the engine. Upsert is a defensible
/// design for a merge-oriented store and this is a category mismatch, not a bug.
/// Whether SwiftData has any other way to hold the invariant is what the probe
/// below tests.
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

    // MARK: Characterisation — SwiftData's declared-constraint semantics

    /// **Characterisation, not a requirement.** This pins SwiftData's observed
    /// behaviour so that a change to it is noticed, and so the ADR reasoning has
    /// a test behind it rather than a sentence.
    ///
    /// Established by CI: `#Unique` does not reject a second occupant of an
    /// occupied slot — it **upserts**, silently overwriting the first row.
    ///
    ///     rows after save: [active-2/slot=c1]     // active-1 is gone, no error
    ///
    /// For scenario B that is worse than no constraint: the second writer must
    /// *fail cleanly*, and instead the first active run disappears without a
    /// trace. The requirement itself is asserted in the Scenario B probe.
    @Test("SwiftData (characterised): an occupied unique slot is silently overwritten")
    @MainActor
    func swiftDataOccupiedSlotIsSilentUpsert() throws {
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

        #expect(
            !threw && rows.count == 1,
            "known behaviour changed — expected the silent upsert. Observed \(outcome). rows after save: [\(dumped)]"
        )
    }

    /// **Characterisation, second hypothesis — also resolved.**
    ///
    /// A non-optional slot is the better *design* anyway: it holds the
    /// conversation id while active and a per-run unique value once terminal, so
    /// uniqueness is unconditional and the engine never depends on SQL's
    /// NULL-is-distinct rule. This test asked whether the optional attribute was
    /// what defeated the constraint.
    ///
    /// It was not. CI observed the same silent upsert:
    ///
    ///     rows for slot c1: [active-2]
    ///
    /// So no column shape rescues SwiftData's declarative uniqueness for an
    /// exclusivity invariant. The sentinel shape is still worth keeping in mind
    /// if a non-declarative mechanism is used.
    @Test("SwiftData (characterised): a non-optional slot is overwritten too")
    @MainActor
    func swiftDataNonNullSlotAlsoUpserts() throws {
        let container = try ModelContainer(
            for: SentinelRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        // Terminal runs carry a per-run key, so they never collide with each other.
        context.insert(SentinelRecord(slot: "run-t1", value: "terminal-1"))
        context.insert(SentinelRecord(slot: "run-t2", value: "terminal-2"))
        try context.save()
        let terminalCount = try context.fetchCount(FetchDescriptor<SentinelRecord>())
        #expect(terminalCount == 2, "distinct terminal keys must coexist")

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

        #expect(
            !threw && rows.count == 1,
            "known behaviour changed — expected the silent upsert. Observed \(outcome). rows for slot c1: [\(dumped)]"
        )
    }
}

// MARK: - Scenario B probe

/// The decisive experiment: can SwiftData hold "at most one active owner" **at
/// all**, if it is not allowed to lean on `#Unique`?
///
/// The engine's declarative constraint upserts rather than rejects, so any
/// SwiftData implementation of scenario B must use something else. The candidate
/// is a fetch-then-insert **inside a transaction**. Whether that is safe depends
/// entirely on the isolation the engine actually provides — and the blueprint
/// forbids "check then write" in business code *unless* the data layer makes it
/// atomic, so this is the right question to put to the engine.
///
/// The model deliberately carries **no** unique attribute: this measures the
/// transaction mechanism alone, with nothing else holding the invariant up.
///
/// ## A correction worth recording
///
/// The first version of this probe reported 3 winners out of 8 — but it fetched
/// and inserted as two separate operations, never wrapping them in a transaction.
/// That is not a test of the engine's isolation; it is a test of a check-then-write
/// with no transaction at all, which obviously races. Reporting it as "SwiftData
/// cannot do this" would have been a wrong conclusion drawn from a broken
/// experiment. The block below is wrapped in `transaction`, and the outcome
/// distinguishes *clean rejection* from *error*, because the two are not the same
/// thing: a busy/locked error is not the "slot already taken" the invariant needs.
@Suite("Scenario B probe")
struct ScenarioBProbeTests {

    @Test("SwiftData: eight concurrent claimants in one transaction each — can exactly one win?")
    func swiftDataConcurrentClaim() async throws {
        let directory = URL.temporaryDirectory.appending(path: "zen-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try ModelContainer(
            for: ClaimRecord.self,
            configurations: ModelConfiguration(url: directory.appending(path: "claims.store"))
        )

        let claimers: [(actor: ClaimActor, owner: String)] = (0..<8).map { index in
            (ClaimActor(modelContainer: container), "w\(index)")
        }

        let outcomes = await withTaskGroup(of: ClaimOutcome.self) { group in
            for (actor, owner) in claimers {
                group.addTask { await actor.tryClaim(conversationID: "c1", owner: owner) }
            }
            var collected: [ClaimOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let winners = outcomes.filter { $0 == .won }
        let rejected = outcomes.filter { $0 == .taken }
        let errored = outcomes.compactMap { outcome -> String? in
            if case .failed(let reason) = outcome { return reason }
            return nil
        }

        // Read back through an actor rather than a fresh `ModelContext` in the test
        // body: the context is not Sendable, and creating one here would be a
        // concurrency question of its own, muddying what this test measures.
        let reader = ClaimActor(modelContainer: container)
        let holders = try await reader.holders(of: "c1")

        #expect(
            winners.count == 1 && holders.count == 1,
            """
            exactly one claimant may hold the slot. \
            won=\(winners.count) rejectedAsTaken=\(rejected.count) errored=\(errored.count); \
            rows holding c1: \(holders.count) [\(holders.sorted().joined(separator: ", "))]; \
            errors: [\(errored.prefix(3).joined(separator: " | "))]. \
            More than one row means the transaction does not serialise the check.
            """
        )
    }

    // MARK: The same race, against GRDB

    /// The counterpart to the SwiftData probe, run so the comparison is
    /// apples-to-apples: same eight concurrent claimants, same "exactly one may
    /// hold the slot" requirement.
    ///
    /// The earlier GRDB uniqueness test was **single-threaded**, which is not
    /// enough to conclude anything about concurrency — a constraint that holds
    /// sequentially can still be defeated by interleaving. This one races.
    ///
    /// The mechanism is the declared constraint (a partial unique index) rather
    /// than a check-then-write, so it does not depend on the engine serialising a
    /// read against a later write. That distinction is the whole point of B.
    @Test("GRDB: eight concurrent claimants against a partial unique index — exactly one wins?")
    func grdbConcurrentClaim() async throws {
        let directory = URL.temporaryDirectory.appending(path: "zen-grdb-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbPool = try DatabasePool(path: directory.appending(path: "claims.sqlite").path())

        try await dbPool.write { db in
            try db.create(table: "claim") { t in
                t.primaryKey("id", .text)
                t.column("activeSlot", .text)
                t.column("owner", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX claim_one_active_per_conversation
                ON claim (activeSlot)
                WHERE activeSlot IS NOT NULL
                """)
        }

        let outcomes = await withTaskGroup(of: ClaimOutcome.self) { group in
            for index in 0..<8 {
                let owner = "w\(index)"
                group.addTask {
                    do {
                        try await dbPool.write { db in
                            try db.execute(
                                sql: "INSERT INTO claim (id, activeSlot, owner) VALUES (?, ?, ?)",
                                arguments: [UUID().uuidString, "c1", owner]
                            )
                        }
                        return .won
                    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                        return .taken
                    } catch {
                        return .failed(String(describing: error))
                    }
                }
            }
            var collected: [ClaimOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        let winners = outcomes.filter { $0 == .won }
        let rejected = outcomes.filter { $0 == .taken }
        let errored = outcomes.compactMap { outcome -> String? in
            if case .failed(let reason) = outcome { return reason }
            return nil
        }

        let holders = try await dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT owner FROM claim WHERE activeSlot = 'c1'")
        }

        #expect(
            winners.count == 1 && holders.count == 1,
            """
            exactly one claimant may hold the slot. \
            won=\(winners.count) rejectedAsTaken=\(rejected.count) errored=\(errored.count); \
            rows holding c1: \(holders.count) [\(holders.sorted().joined(separator: ", "))]; \
            errors: [\(errored.prefix(3).joined(separator: " | "))].
            """
        )
    }
}

/// Distinguishing "the slot was already taken" from "the write failed" matters:
/// only the first is the clean rejection the invariant requires. Both engines are
/// scored with this same type, so their results are directly comparable.
enum ClaimOutcome: Sendable, Equatable {
    case won
    case taken
    case failed(String)
}

/// One writer. `@ModelActor` gives each instance its own `ModelContext`, which is
/// what makes two of them able to race — a single context serialises its own work
/// and would hide the problem.
///
/// The `owner` is passed per call rather than stored, so the macro-generated
/// `init(modelContainer:)` can be used as-is. Hand-writing that initialiser would
/// mean reproducing the macro's `modelExecutor` setup, and getting it subtly wrong
/// would look like an engine failure rather than a test bug.
@ModelActor
actor ClaimActor {
    /// Claim the slot for this conversation, or report why not.
    ///
    /// The fetch **and** the insert are inside one `transaction`, because a check
    /// and a write in separate operations is not a test of the engine's isolation
    /// — it is a test of a race, which trivially loses.
    func tryClaim(conversationID: String, owner: String) -> ClaimOutcome {
        let target = conversationID
        do {
            var won = false
            try modelContext.transaction {
                let descriptor = FetchDescriptor<ClaimRecord>(
                    predicate: #Predicate { $0.activeSlot == target }
                )
                guard try modelContext.fetchCount(descriptor) == 0 else { return }
                modelContext.insert(ClaimRecord(activeSlot: conversationID, owner: owner))
                try modelContext.save()
                won = true
            }
            return won ? .won : .taken
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Committed holders of a slot, as owner names.
    func holders(of conversationID: String) throws -> [String] {
        let target = conversationID
        let descriptor = FetchDescriptor<ClaimRecord>(
            predicate: #Predicate { $0.activeSlot == target }
        )
        return try modelContext.fetch(descriptor).map(\.owner)
    }
}

/// No declared uniqueness — deliberately. See the suite comment.
@Model
final class ClaimRecord {
    var activeSlot: String
    var owner: String

    init(activeSlot: String, owner: String) {
        self.activeSlot = activeSlot
        self.owner = owner
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
