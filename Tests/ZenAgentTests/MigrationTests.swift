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
/// Earlier this used a synthetic v2, on the grounds that a migration test needs *a*
/// second migration rather than the real one. Now that the production v2 exists, the
/// upgrade cases use it — testing the real path beats testing a stand-in for it. The
/// interruption case still needs a migration of its own, because the real one is not
/// supposed to fail.
@Suite("Migration")
struct MigrationTests {

    /// A migration that alters the schema and then dies, as a process killed partway
    /// through would.
    private enum InterruptingV3 {
        static func register(_ migrator: inout DatabaseMigrator) {
            migrator.registerMigration("v3_test_never_completes") { db in
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

    private func currentMigrator() -> DatabaseMigrator {
        Migrations.makeMigrator()
    }

    private func seedV1(at url: URL) throws {
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v1Migrator()))
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
    }

    private func hasAgentStepTable(_ store: PersistenceStore) throws -> Bool {
        try store.database.read { db in
            try db.tableExists("agentStep")
        }
    }

    // MARK: D1

    @Test("V1 → V2 applies, and existing rows survive")
    func migrationApplies() throws {
        let url = try Fixtures.scratchPath(name: "migrate.sqlite")
        defer { Fixtures.cleanUp(url) }

        try seedV1(at: url)

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator()))
        #expect(try hasAgentStepTable(store), "the V2 schema must be present after upgrading")
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
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator()))
            #expect(try hasAgentStepTable(store))
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

        var failure: Error?
        do {
            var migrator = currentMigrator()
            InterruptingV3.register(&migrator)
            _ = try ZenDatabase.open(at: url.path(), migrator: migrator)
        } catch {
            failure = error
        }
        #expect(
            failure is MigrationInterruptedInTest,
            "the interrupted migration must surface its own failure; got \(String(describing: failure))"
        )

        // Still openable, still holding the data, and the schema is the last one that
        // actually completed.
        let afterFailure = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator()))
        #expect(
            try afterFailure.messages(inConversation: "c1").count == 1,
            "an interrupted migration must not lose committed data"
        )
        #expect(
            try afterFailure.database.read { db in try db.columns(in: "conversation").map(\.name) }
                .contains("archived") == false,
            "a failed migration must roll back entirely, not leave a half-applied schema"
        )
        #expect(
            try hasAgentStepTable(afterFailure),
            "and the migrations that had already completed must still be there"
        )
    }

    // MARK: the new table itself

    @Test("the V2 table is usable and enforces one row per attempt")
    func agentStepTableEnforcesItsKey() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))

        var failure: Error?
        do {
            try store.recordStep(Fixtures.step(stepID: "s1", runID: "r1", attempt: 1))
        } catch {
            failure = error
        }

        // Asserted here as well as in the behaviour suite: the composite key is a
        // schema property, and a migration that created the table without it would
        // otherwise pass every other test.
        #expect(failure != nil, "the composite primary key must exist in the migrated schema")
    }
}

/// Raised to interrupt a migration partway. Distinct from any other test's error type so
/// a failure here cannot be confused with a different injected failure.
struct MigrationInterruptedInTest: Error {}
