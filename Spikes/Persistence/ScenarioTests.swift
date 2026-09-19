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
@Suite("Scenario D — migration interruption")
struct ScenarioDTests {

    private func establishV1(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-note") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("body", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO note (id, body) VALUES ('n1', 'hello')")
        }
        try migrator.migrate(queue)
    }

    @Test("D · GRDB — an interrupted migration rolls back and can be re-run")
    func grdbMigrationInterruption() throws {
        let url = try makeScratchPath(name: "grdb-migrate.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        // Establish v1 with real data, then let the writer go.
        do {
            try establishV1(try DatabaseQueue(path: path))
        }

        // A migration that does part of its work and then fails, as a process that
        // died mid-migration would.
        do {
            let queue = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1-note") { db in
                try db.create(table: "note") { t in
                    t.primaryKey("id", .text)
                    t.column("body", .text).notNull()
                }
                try db.execute(sql: "INSERT INTO note (id, body) VALUES ('n1', 'hello')")
            }
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

        // The store must still open, still hold the data, and not carry half a schema.
        do {
            let queue = try DatabaseQueue(path: path)
            let body = try queue.read { db in
                try String.fetchOne(db, sql: "SELECT body FROM note WHERE id = 'n1'")
            }
            #expect(body == "hello", "an interrupted migration must not lose committed data")

            let columns = try queue.read { db in try db.columns(in: "note").map(\.name) }
            #expect(
                !columns.contains("pinned"),
                "a failed migration must roll back entirely, not leave a half-applied schema; columns were \(columns)"
            )
        }

        // And the corrected migration must apply cleanly over the intact data.
        do {
            let queue = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1-note") { db in
                try db.create(table: "note") { t in
                    t.primaryKey("id", .text)
                    t.column("body", .text).notNull()
                }
                try db.execute(sql: "INSERT INTO note (id, body) VALUES ('n1', 'hello')")
            }
            migrator.registerMigration("v2-add-pinned") { db in
                try db.alter(table: "note") { t in
                    t.add(column: "pinned", .boolean).notNull().defaults(to: false)
                }
            }
            try migrator.migrate(queue)

            let body = try queue.read { db in
                try String.fetchOne(db, sql: "SELECT body FROM note WHERE id = 'n1'")
            }
            let columns = try queue.read { db in try db.columns(in: "note").map(\.name) }
            let rows = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1 }

            #expect(body == "hello", "re-running the migration must not disturb existing rows")
            #expect(rows == 1, "re-running must not duplicate rows; found \(rows)")
            #expect(columns.contains("pinned"), "the retried migration must actually apply; columns were \(columns)")
        }
    }
}

// MARK: - Shared helpers

private func describe(_ value: String?) -> String {
    value.map { "\"\($0)\"" } ?? "nothing"
}

private func makeScratchPath(name: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "zen-spike-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: name)
}

private func cleanUp(_ url: URL) {
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
