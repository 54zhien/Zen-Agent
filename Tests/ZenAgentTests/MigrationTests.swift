import Foundation
import Testing

import GRDB

@testable import ZenAgent

/// Product invariant: **a schema migration either completes or rolls back, and can be
/// re-run afterwards.**
///
/// The requirement is not "migrations work". It is that a migration interrupted partway
/// leaves the store usable at its previous version with its data intact, and that
/// running it again succeeds. Getting this wrong is how a shipping app loses user data
/// on update: the schema lands half-applied and nothing can open the store.
///
/// The v2 here is a **test-only** migration. Production carries one migration, because
/// inventing a future table purely to have something to migrate would be putting
/// scaffolding in the schema for the sake of a test. A migration test needs *a* second
/// migration, not the real one.
@Suite("Migration")
struct MigrationTests {

    /// A second migration that exists only here.
    private enum TestV2 {
        static func register(_ migrator: inout DatabaseMigrator) {
            migrator.registerMigration("v2_test_add_archived") { db in
                try db.alter(table: "conversation") { t in
                    t.add(column: "archived", .boolean).notNull().defaults(to: false)
                }
            }
        }

        static func registerBroken(_ migrator: inout DatabaseMigrator) {
            migrator.registerMigration("v2_test_add_archived_BROKEN") { db in
                try db.alter(table: "conversation") { t in
                    t.add(column: "archived", .boolean).notNull().defaults(to: false)
                }
                throw MigrationInterruptedInTest()
            }
        }
    }

    private func v1Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        return migrator
    }

    private func v1AndV2Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        TestV2.register(&migrator)
        return migrator
    }

    private func seedV1(at url: URL) throws {
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1Migrator()))
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
    }

    private func hasArchivedColumn(_ store: PersistenceStore) throws -> Bool {
        try store.database.read { db in
            try db.columns(in: "conversation").contains { $0.name == "archived" }
        }
    }

    // MARK: D1

    @Test("V1 → V2 applies, and existing rows survive")
    func migrationApplies() throws {
        let url = try Fixtures.scratchPath(name: "migrate.sqlite")
        defer { Fixtures.cleanUp(url) }

        try seedV1(at: url)

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1AndV2Migrator()))
        #expect(try hasArchivedColumn(store), "the V2 schema must be present after upgrading")
        #expect(
            try store.messages(inConversation: "c1").count == 1,
            "the row written before the migration must survive it"
        )
    }

    // MARK: D2

    @Test("reopening after a migration neither re-applies nor duplicates")
    func migrationIsNotReapplied() throws {
        let url = try Fixtures.scratchPath(name: "migrate-twice.sqlite")
        defer { Fixtures.cleanUp(url) }

        try seedV1(at: url)

        for _ in 0..<2 {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1AndV2Migrator()))
            #expect(try hasArchivedColumn(store))
            #expect(
                try store.messages(inConversation: "c1").count == 1,
                "reopening must not re-run the migration and duplicate its data"
            )
        }
    }

    // MARK: D3

    @Test("an interrupted migration rolls back and can be resumed")
    func interruptedMigrationRollsBack() throws {
        let url = try Fixtures.scratchPath(name: "migrate-broken.sqlite")
        defer { Fixtures.cleanUp(url) }

        try seedV1(at: url)

        // A migration that alters the schema and then fails, as a process dying partway
        // through would.
        var failure: Error?
        do {
            var migrator = v1Migrator()
            TestV2.registerBroken(&migrator)
            _ = try ZenDatabase.open(at: url.path(), migrator: migrator)
        } catch {
            failure = error
        }
        #expect(
            failure is MigrationInterruptedInTest,
            "the interrupted migration must surface its own failure; got \(String(describing: failure))"
        )

        // Still openable, still holding the data, carrying no half-applied schema.
        let afterFailure = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1Migrator()))
        #expect(
            try afterFailure.messages(inConversation: "c1").count == 1,
            "an interrupted migration must not lose committed data"
        )
        #expect(
            try !hasArchivedColumn(afterFailure),
            "a failed migration must roll back entirely, not leave a half-applied schema"
        )

        // And the corrected migration applies cleanly over the intact data.
        let resumed = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1AndV2Migrator()))
        #expect(try hasArchivedColumn(resumed), "the resumed migration must actually apply")
        #expect(
            try resumed.messages(inConversation: "c1").count == 1,
            "resuming must not disturb existing rows"
        )
    }
}

/// Raised to interrupt a migration partway. Separate from any other test's error type so
/// a failure here cannot be confused with a different injected failure.
struct MigrationInterruptedInTest: Error {}
