import Foundation
import Testing

import GRDB
import SwiftData

/// Scenario C — the crash window.
///
/// The blueprint requires that after a crash, recovery can tell *"prepared but
/// never dispatched"* from *"possibly dispatched"*. Only the first may be
/// re-executed; the second must become `indeterminate` and never auto-retry.
///
/// The engine's job here is narrow but load-bearing: a small state marker must be
/// **durably committed**, and the two states must stay **distinguishable** once the
/// writer is gone. If `dispatching` reads back as `prepared`, recovery re-dispatches
/// a write that may already have reached the outside world — exactly the failure
/// the `indeterminate` concept exists to prevent.
///
/// "The process died" is simulated by releasing the writer entirely and opening a
/// **fresh, independent handle over the same file**. That is what a crash leaves
/// behind: a file, and nothing else. Reading back through the original handle would
/// prove nothing, because it could be serving the write from memory.
///
/// The ordering being asserted is the one the design depends on — `dispatching` is
/// committed **before** the external call is made. That is what makes the uncertain
/// window *possibly dispatched* rather than *unknown*, and it is why the safe
/// failure mode is "refuse to retry" rather than "retry and hope".
@Suite("Scenario C — crash window")
struct ScenarioCTests {

    /// The ToolCall phases that matter for the crash window. Deliberately just the
    /// ones C is about; `succeeded`/`failed` are terminal and not a recovery risk.
    enum Phase: String {
        case prepared
        case dispatching
    }

    // MARK: - GRDB

    @Test("C · GRDB — prepared and dispatching survive a reopen, still distinguishable")
    func grdbCrashWindow() throws {
        let url = try makeScratchPath(name: "grdb-tools.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        // Prepared is committed before anything leaves the process.
        do {
            let pool = try DatabasePool(path: path)
            try pool.write { db in
                try db.create(table: "toolCall") { t in
                    t.primaryKey("id", .text)
                    t.column("phase", .text).notNull()
                    t.column("attempt", .integer).notNull()
                }
                try db.execute(
                    sql: "INSERT INTO toolCall (id, phase, attempt) VALUES (?, ?, ?)",
                    arguments: ["tc1", Phase.prepared.rawValue, 1]
                )
            }
        }
        let afterPrepared = try grdbPhase(path)
        #expect(
            afterPrepared == Phase.prepared.rawValue,
            "prepared must be durable after the writer is gone; read back \(describe(afterPrepared))"
        )

        // The writer is gone. This is the crash. Recovery now commits the marker
        // that says "an external call is about to be attempted" — still before it
        // is attempted.
        do {
            let pool = try DatabasePool(path: path)
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE toolCall SET phase = ? WHERE id = ?",
                    arguments: [Phase.dispatching.rawValue, "tc1"]
                )
            }
        }
        let recovered = try grdbPhase(path)

        #expect(
            recovered == Phase.dispatching.rawValue,
            """
            recovery must see \(Phase.dispatching.rawValue), not \(describe(recovered)). \
            Reading back \(describe(recovered)) means the two states collapsed and \
            recovery would re-dispatch a call that may already have happened.
            """
        )
    }

    // MARK: - SwiftData

    @Test("C · SwiftData — prepared and dispatching survive a reopen, still distinguishable")
    @MainActor
    func swiftDataCrashWindow() throws {
        let url = try makeScratchPath(name: "swiftdata-tools.store")
        defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: ToolCallRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.insert(ToolCallRecord(id: "tc1", phase: Phase.prepared.rawValue, attempt: 1))
            try context.save()
        }
        let afterPrepared = try swiftDataPhase(url)
        #expect(
            afterPrepared == Phase.prepared.rawValue,
            "prepared must be durable after the writer is gone; read back \(describe(afterPrepared))"
        )

        do {
            let container = try ModelContainer(
                for: ToolCallRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            guard let existing = try context.fetch(FetchDescriptor<ToolCallRecord>()).first else {
                Issue.record("expected the tool call to survive the reopen, found none")
                return
            }
            existing.phase = Phase.dispatching.rawValue
            try context.save()
        }
        let recovered = try swiftDataPhase(url)

        #expect(
            recovered == Phase.dispatching.rawValue,
            """
            recovery must see \(Phase.dispatching.rawValue), not \(describe(recovered)). \
            Reading back \(describe(recovered)) means the two states collapsed and \
            recovery would re-dispatch a call that may already have happened.
            """
        )
    }

    // MARK: - Helpers

    private func grdbPhase(_ path: String) throws -> String? {
        let pool = try DatabasePool(path: path)
        return try pool.read { db in
            try String.fetchOne(db, sql: "SELECT phase FROM toolCall WHERE id = 'tc1'")
        }
    }

    @MainActor
    private func swiftDataPhase(_ url: URL) throws -> String? {
        let container = try ModelContainer(
            for: ToolCallRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ToolCallRecord>()).first?.phase
    }
}

// MARK: - Scenario D — migration interruption

/// Raised by a deliberately broken migration to simulate a process dying partway
/// through schema work.
struct MigrationInterrupted: Error {}

/// Scenario D — an interrupted migration must roll back, and must be re-runnable.
///
/// The requirement is not merely "migrations work". It is that a migration
/// interrupted partway leaves the store **usable at its previous version with its
/// data intact**, and that re-running it afterwards succeeds. Getting this wrong is
/// how a shipping app loses user data on an update: the schema lands half-applied
/// and nothing can open the store.
///
/// Before release this is also a backup question, but at the engine level the
/// question is whether each migration step is transactional and whether the
/// bookkeeping that records "this migration already ran" rolls back with it.
@Suite("Scenario D — migration")
struct ScenarioDTests {

    // MARK: Shared migration definitions

    private func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-note") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("body", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO note (id, body) VALUES ('n1', 'hello')")
        }
    }

    private func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-add-pinned") { db in
            try db.alter(table: "note") { t in
                t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            }
        }
    }

    /// Establishes a store at v1 holding one row, then releases the writer.
    private func establishV1(name: String) throws -> URL {
        let url = try makeScratchPath(name: name)
        let queue = try DatabaseQueue(path: url.path())
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        try migrator.migrate(queue)
        return url
    }

    private func inspect(_ path: String) throws -> (body: String?, rowCount: Int, columns: [String]) {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            (
                body: try String.fetchOne(db, sql: "SELECT body FROM note WHERE id = 'n1'"),
                rowCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1,
                columns: try db.columns(in: "note").map(\.name)
            )
        }
    }

    // MARK: D1 — the migration itself

    @Test("D1 · GRDB — V1 → V2 applies, schema changes, existing rows survive")
    func grdbNormalMigration() throws {
        let url = try establishV1(name: "grdb-d1.sqlite")
        defer { cleanUp(url) }

        let queue = try DatabaseQueue(path: url.path())
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        try migrator.migrate(queue)

        let state = try inspect(url.path())
        #expect(state.columns.contains("pinned"), "V2 schema must be present; columns were \(state.columns)")
        #expect(state.body == "hello", "the existing row must survive the migration")
        #expect(state.rowCount == 1, "the migration must not duplicate rows; found \(state.rowCount)")
    }

    // MARK: D2 — reopening after a completed migration

    @Test("D2 · GRDB — reopening after migration neither re-applies nor duplicates")
    func grdbRepeatedOpen() throws {
        let url = try establishV1(name: "grdb-d2.sqlite")
        defer { cleanUp(url) }

        do {
            let queue = try DatabaseQueue(path: url.path())
            var migrator = DatabaseMigrator()
            registerV1(&migrator)
            registerV2(&migrator)
            try migrator.migrate(queue)
        }

        // Same migrations registered again: GRDB must see them as already applied.
        // Re-running the v1 migration would insert a second row — that is the
        // failure this checks for, and it is silent if you only look at the schema.
        do {
            let queue = try DatabaseQueue(path: url.path())
            var migrator = DatabaseMigrator()
            registerV1(&migrator)
            registerV2(&migrator)
            try migrator.migrate(queue)
        }

        let state = try inspect(url.path())
        #expect(state.rowCount == 1, "reopening must not re-run migrations; found \(state.rowCount) rows")
        #expect(state.body == "hello", "reopening must not disturb the row")
        #expect(state.columns.contains("pinned"), "the migrated schema must still be in place")
    }

    // MARK: D3 — interruption

    /// The failure is injected as a thrown error inside the migration body. That is
    /// a **controlled** interruption, not a process killed mid-write — see the
    /// controllability note in `README.md`. What it can prove is that a failed
    /// migration rolls back atomically and leaves the store usable; what it cannot
    /// prove is behaviour under an actual untimely kill.
    @Test("D3 · GRDB — an interrupted migration rolls back and can be resumed")
    func grdbInterruptedMigration() throws {
        let url = try establishV1(name: "grdb-d3.sqlite")
        defer { cleanUp(url) }

        // A migration that alters the schema and then fails.
        do {
            let queue = try DatabaseQueue(path: url.path())
            var migrator = DatabaseMigrator()
            registerV1(&migrator)
            migrator.registerMigration("v2-add-pinned-BROKEN") { db in
                try db.alter(table: "note") { t in
                    t.add(column: "pinned", .boolean).notNull().defaults(to: false)
                }
                throw MigrationInterrupted()
            }
            var failure: Error?
            do { try migrator.migrate(queue) } catch { failure = error }
            #expect(
                failure is MigrationInterrupted,
                "the interrupted migration must surface its failure; got \(String(describing: failure))"
            )
        }

        // Still openable, still holding the data, carrying no half-applied schema.
        let afterFailure = try inspect(url.path())
        #expect(afterFailure.body == "hello", "an interrupted migration must not lose committed data")
        #expect(
            !afterFailure.columns.contains("pinned"),
            "a failed migration must roll back entirely; columns were \(afterFailure.columns)"
        )

        // And the corrected migration must apply cleanly over the intact data.
        do {
            let queue = try DatabaseQueue(path: url.path())
            var migrator = DatabaseMigrator()
            registerV1(&migrator)
            registerV2(&migrator)
            try migrator.migrate(queue)
        }

        let resumed = try inspect(url.path())
        #expect(resumed.body == "hello", "resuming must not disturb existing rows")
        #expect(resumed.rowCount == 1, "resuming must not duplicate rows; found \(resumed.rowCount)")
        #expect(resumed.columns.contains("pinned"), "the resumed migration must actually apply")
    }
}

// MARK: - Scenario D, SwiftData half

/// Schema version 1. Models are nested inside the versioned schema, which is how
/// SwiftData keeps two shapes of the same entity apart.
enum NoteSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model
    final class Note {
        var id: String
        var body: String

        init(id: String, body: String) {
            self.id = id
            self.body = body
        }
    }
}

enum NoteSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model
    final class Note {
        var id: String
        var body: String
        /// **Optional on purpose.** CI established that adding a *non-optional*
        /// attribute fails the migration outright:
        ///
        ///     Cannot migrate store in-place: Validation error missing attribute
        ///     values on mandatory destination attribute
        ///       entity=Note, attribute=pinned
        ///
        /// A constructor default does not help — the schema needs a value for
        /// existing rows, and only an optional attribute or an explicit backfill
        /// supplies one. This is the shape that would break an app update.
        var pinned: Bool?

        init(id: String, body: String, pinned: Bool? = nil) {
            self.id = id
            self.body = body
            self.pinned = pinned
        }
    }
}

/// The working migration. `stages` is computed rather than a stored `static let`
/// so there is no shared mutable global to argue with strict concurrency about.
///
/// The `didMigrate` backfill is not decoration: an added optional attribute arrives
/// `nil` for pre-existing rows, so anything that needs a value must be filled in
/// here. Demonstrating that path is part of what D1 is for.
enum NoteMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [NoteSchemaV1.self, NoteSchemaV2.self] }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: NoteSchemaV1.self,
                toVersion: NoteSchemaV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    let notes = try context.fetch(FetchDescriptor<NoteSchemaV2.Note>())
                    for note in notes where note.pinned == nil {
                        note.pinned = false
                    }
                    try context.save()
                }
            )
        ]
    }
}

/// The same migration, made to fail. See D3.
///
/// It uses the *working* V2 shape, so the only reason it can fail is the injected
/// error. A broken schema would have failed D3 for the wrong reason and made the
/// test look like it passed.
enum BrokenNoteMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [NoteSchemaV1.self, NoteSchemaV2.self] }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: NoteSchemaV1.self,
                toVersion: NoteSchemaV2.self,
                willMigrate: { _ in throw MigrationInterrupted() },
                didMigrate: nil
            )
        ]
    }
}

/// Scenario D, SwiftData half — the same three questions as the GRDB side, so the
/// two are directly comparable.
///
/// A note on what D3 can and cannot establish here. SwiftData runs migrations
/// implicitly when a `ModelContainer` is initialised, and the public surface is
/// `VersionedSchema` / `SchemaMigrationPlan` / `MigrationStage` — there is no
/// handle for stepping or pausing a migration. So the interruption has to be
/// injected as a thrown error inside a migration stage, which is a **controlled**
/// failure rather than a process killed mid-write.
///
/// That distinction is recorded deliberately. "Cannot inject the exact failure" is
/// a statement about **controllability and observability**, not about whether the
/// engine is safe. Collapsing the two would be the same overreach this project has
/// already made twice.
@Suite("Scenario D — migration (SwiftData)")
struct ScenarioDSwiftDataTests {

    @MainActor
    private func establishV1(at url: URL) throws {
        let container = try ModelContainer(
            for: NoteSchemaV1.Note.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        context.insert(NoteSchemaV1.Note(id: "n1", body: "hello"))
        try context.save()
    }

    // MARK: D1

    @Test("D1 · SwiftData — V1 → V2 applies, existing rows survive")
    @MainActor
    func swiftDataNormalMigration() throws {
        let url = try makeScratchPath(name: "swiftdata-d1.store")
        defer { cleanUp(url) }

        try establishV1(at: url)

        let container = try ModelContainer(
            for: NoteSchemaV2.Note.self,
            migrationPlan: NoteMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<NoteSchemaV2.Note>())

        #expect(notes.count == 1, "the existing row must survive the migration; found \(notes.count)")
        #expect(notes.first?.body == "hello", "the migrated row must keep its content")
        #expect(
            notes.first?.pinned == false,
            "the didMigrate backfill must have filled the new attribute; found \(String(describing: notes.first?.pinned))"
        )
    }

    // MARK: D2

    @Test("D2 · SwiftData — reopening after migration neither re-applies nor duplicates")
    @MainActor
    func swiftDataRepeatedOpen() throws {
        let url = try makeScratchPath(name: "swiftdata-d2.store")
        defer { cleanUp(url) }

        try establishV1(at: url)

        for _ in 0..<2 {
            let container = try ModelContainer(
                for: NoteSchemaV2.Note.self,
                migrationPlan: NoteMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            let count = try context.fetchCount(FetchDescriptor<NoteSchemaV2.Note>())
            #expect(count == 1, "reopening must not re-run or duplicate; found \(count) rows")
        }
    }

    // MARK: D3

    @Test("D3 · SwiftData — a failing migration must not leave an unusable store")
    @MainActor
    func swiftDataInterruptedMigration() throws {
        let url = try makeScratchPath(name: "swiftdata-d3.store")
        defer { cleanUp(url) }

        try establishV1(at: url)

        // Inject the failure. The assertion names the *injected* error rather than
        // merely "something failed": an earlier version accepted any error, which
        // would have passed for an unrelated schema problem and reported a
        // migration defect as a working interruption path.
        var failure: Error?
        do {
            _ = try ModelContainer(
                for: NoteSchemaV2.Note.self,
                migrationPlan: BrokenNoteMigrationPlan.self,
                configurations: ModelConfiguration(url: url)
            )
        } catch {
            failure = error
        }
        #expect(failure != nil, "the broken migration must surface a failure, not silently succeed")

        // Characterisation, recorded rather than endorsed.
        //
        // The injected error *does* propagate into CoreData and *does* abort the
        // migration — the CoreData log shows `returned error
        // PersistenceSpikeTests.MigrationInterrupted (1)`. But SwiftData wraps it in
        // a generic container error with `_explanation: nil`, so the caller cannot
        // read the cause.
        //
        // That is a **diagnosability** finding, not a correctness one. The migration
        // aborts and the store stays usable; what is lost is any way to tell "my
        // migration code threw" apart from "the schema is wrong" or "the store is
        // corrupt". For an app where a failed migration means the user cannot open
        // it at all, that is a meaningful loss.
        //
        // If this ever stops holding, the diagnosability note in README.md and
        // Docs/ADR/0001 is out of date.
        let surfaced = String(describing: failure)
        #expect(
            !surfaced.contains("MigrationInterrupted"),
            """
            known SwiftData behaviour changed: the underlying migration cause now \
            surfaces to the caller. Surfaced: \(surfaced)
            """
        )

        // The store must still be openable and still hold the data. Note the
        // assertion is *"usable"*, not *"rolled back to V1"*: SwiftData gives no
        // way to ask which schema version a store is at, so the stronger claim
        // cannot be checked here — and asserting it anyway would be invention.
        do {
            let container = try ModelContainer(
                for: NoteSchemaV1.Note.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            let notes = try context.fetch(FetchDescriptor<NoteSchemaV1.Note>())
            #expect(
                notes.count == 1 && notes.first?.body == "hello",
                "after a failed migration the store must still open and hold its data; found \(notes.count) row(s)"
            )
        } catch {
            Issue.record(
                """
                the store could not be reopened at V1 after a failed migration: \(error). \
                That is a controllability/recoverability finding about SwiftData's migration, \
                not by itself evidence that migrations are unsafe.
                """
            )
        }
    }
}

// MARK: - Shared helpers

/// File-private to this file.
private func describe(_ value: String?) -> String {
    value.map { "\"\($0)\"" } ?? "nothing"
}

/// Shared across the scenario files — every scenario needs a throwaway store and a
/// temp directory to put it in.
func makeScratchPath(name: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "zen-spike-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: name)
}

func cleanUp(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Throwaway model for scenario C. Not a draft of a product entity.
///
/// `phase` is stored as a raw string rather than an enum so the probe measures the
/// engine's durability, not its Codable handling.
@Model
final class ToolCallRecord {
    var id: String
    var phase: String
    var attempt: Int

    init(id: String, phase: String, attempt: Int) {
        self.id = id
        self.phase = phase
        self.attempt = attempt
    }
}
