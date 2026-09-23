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

    /// The schema as it stood immediately before V5, so the upgrade off it can be
    /// exercised over a real store rather than a synthetic one.
    private func v4Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        Migrations.registerV2(&migrator)
        Migrations.registerV3(&migrator)
        Migrations.registerV4(&migrator)
        return migrator
    }

    private func v5Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        Migrations.registerV2(&migrator)
        Migrations.registerV3(&migrator)
        Migrations.registerV4(&migrator)
        Migrations.registerV5(&migrator)
        return migrator
    }

    /// The schema as it stood immediately before V7, so the tool-continuation
    /// upgrade can be exercised over a real store rather than a synthetic one.
    private func v6Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        Migrations.registerV2(&migrator)
        Migrations.registerV3(&migrator)
        Migrations.registerV4(&migrator)
        Migrations.registerV5(&migrator)
        Migrations.registerV6(&migrator)
        return migrator
    }

    private func v7Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.registerV1(&migrator)
        Migrations.registerV2(&migrator)
        Migrations.registerV3(&migrator)
        Migrations.registerV4(&migrator)
        Migrations.registerV5(&migrator)
        Migrations.registerV6(&migrator)
        Migrations.registerV7(&migrator)
        return migrator
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

    @Test("V5 → V6 adds file asset identity tables and preserves messages")
    func migrationAddsFileAssetIdentityTables() throws {
        let url = try Fixtures.scratchPath(name: "file-asset-migration.sqlite")
        defer { Fixtures.cleanUp(url) }

        let before = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: v5Migrator())
        )
        try before.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m1", runID: "r1")
        )
        #expect(
            try before.database.read { db in try db.tableExists("fileAsset") } == false,
            "the V5 schema must not already carry the V6 table"
        )

        let after = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator())
        )
        #expect(try after.database.read { db in try db.tableExists("fileAsset") })
        #expect(try after.database.read { db in try db.tableExists("fileAssetVersion") })
        #expect(try after.database.read { db in try db.tableExists("messageAttachment") })
        #expect(
            try after.messages(inConversation: "c1").contains { $0.id == "m1" },
            "an existing Message must survive the V5 to V6 migration"
        )
    }

    @Test("V6 → V7 adds tool continuation state and preserves existing tool calls")
    func v6ToV7PreservesExistingToolCalls() throws {
        let url = try Fixtures.scratchPath(name: "tool-continuation-migration.sqlite")
        defer { Fixtures.cleanUp(url) }

        let before = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: v6Migrator())
        )
        try before.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m-v6", runID: "run-v6")
        )
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try before.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO toolCall
                    (id, agentRunID, action, state, executionIntent, attempt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: StatementArguments([
                    "call-v6", "run-v6", "legacy", ToolCallState.prepared.rawValue,
                    "{}", 1, oldDate, oldDate,
                ])
            )
        }

        let after = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator())
        )

        let oldCall = try after.toolCall(id: "call-v6")
        #expect(oldCall?.id == "call-v6")
        #expect(oldCall?.providerCallID == nil)
        #expect(oldCall?.batchID == nil)
        #expect(oldCall?.batchSequence == nil)
        #expect(try after.database.read { db in try db.tableExists("toolResult") })

        let newCall = ToolCallRecord(
            id: "call-v7",
            agentRunID: "run-v6",
            action: "stage2",
            state: .succeeded,
            executionIntent: "{}",
            attempt: 1,
            providerCallID: "provider-v7",
            batchID: "batch-v7",
            batchSequence: 4,
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let newResult = ToolResultRecord(
            toolCallID: newCall.id,
            payload: "round trip",
            createdAt: oldDate
        )
        try after.createToolCall(newCall)
        try after.database.write { db in
            try newResult.insert(db)
        }

        let roundTripped = try after.toolCall(id: newCall.id)
        let roundTrippedResult = try after.toolResult(toolCallID: newCall.id)
        #expect(roundTripped?.providerCallID == "provider-v7")
        #expect(roundTripped?.batchID == "batch-v7")
        #expect(roundTripped?.batchSequence == 4)
        #expect(roundTrippedResult?.payload == "round trip")
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

    // MARK: - The edit revision

    @Test("an instance written before the edit revision existed upgrades to the start of its counter")
    func editRevisionUpgradesFromV4() throws {
        let url = try Fixtures.scratchPath(name: "edit-revision.sqlite")
        defer { Fixtures.cleanUp(url) }

        // A store from before V5, holding an instance row of the shape that build wrote.
        //
        // Written with SQL rather than through `createProviderInstance`, because the
        // typed path writes the column V5 adds and this store does not have it yet. A
        // row that no typed API of *this* build can produce is exactly what an upgrade
        // test needs.
        let instanceID = ProviderInstanceID(rawValue: "pi-1")
        let before = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: v4Migrator()))
        try before.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO providerInstance
                        (id, providerID, displayName, baseURL, configRevision,
                         credentialID, credentialKind, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                    """,
                arguments: [
                    instanceID.rawValue, "deepseek", "DeepSeek",
                    "https://api.deepseek.com", ConfigRevision.initial.rawValue,
                    Fixtures.epoch, Fixtures.epoch,
                ]
            )
        }
        #expect(
            try before.database.read { db in try db.columns(in: "providerInstance").map(\.name) }
                .contains("editRevision") == false,
            "the V4 schema must not already carry the column, or this test proves nothing"
        )

        // Reopened under the production migrator, the row survives and the counter starts
        // where the mutation path expects it to.
        let after = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator()))
        let upgraded = try after.providerInstance(id: instanceID)
        #expect(upgraded?.displayName == "DeepSeek", "the row must survive the migration")
        #expect(upgraded?.editRevision == .initial, "and it must start at the counter's zero")

        // And the upgraded row is editable. This is what a wrong default would break: a
        // revision the caller cannot match is one no edit can ever be made against.
        let edited = try after.reconfigureProviderInstance(
            id: instanceID,
            displayName: "renamed",
            baseURL: nil,
            expectedEditRevision: .initial
        )
        #expect(edited.displayName == "renamed")
        #expect(edited.editRevision != .initial, "the edit must move the counter forward")
    }

    // MARK: - An unreadable frozen seed

    /// Writes `seed` straight into the column, bypassing every typed path.
    ///
    /// Which is the point: these rows are what an older build, or a damaged database,
    /// actually leaves behind, and no typed API can produce one.
    private func plantSeed(_ seed: String, forRun id: String, in store: PersistenceStore) throws {
        try store.database.write { db in
            try db.execute(
                sql: "UPDATE agentRun SET requestConfigSeed = ? WHERE id = ?",
                arguments: [seed, id]
            )
        }
    }

    private func readFailure(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    @Test("a seed written before versioning is reported, not crashed on")
    func legacySeedIsReported() throws {
        let url = try Fixtures.scratchPath(name: "legacy-seed.sqlite")
        defer { Fixtures.cleanUp(url) }

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // The pre-versioning shape: no `formatVersion`, and the old P6 field name rather
        // than today's `credentialBinding`.
        //
        // No test has ever put one of these in the database. That is precisely why the
        // reader's behaviour on one was unknown.
        let legacy = #"{"providerInstanceID":"pi1","modelID":"deepseek-chat","providerConfigRevision":"config-r1","credentialBindingRevision":1}"#
        try plantSeed(legacy, forRun: "r1", in: store)

        // Both readers, because they reached the column by different routes.
        let fromRun = readFailure { _ = try store.run(id: "r1") }
        #expect(
            fromRun as? ZenAgent.PersistenceError
                == .unreadableRequestConfigSeed(runID: "r1", failure: .unversioned),
            """
            expected a typed failure naming the run; got \(String(describing: fromRun)). \
            Before this change GRDB's own decoding error came out here - a storage-engine \
            type in front of the caller, about a payload problem.
            """
        )

        let fromActive = readFailure { _ = try store.activeParentRuns(inConversation: "c1") }
        #expect(
            fromActive as? ZenAgent.PersistenceError
                == .unreadableRequestConfigSeed(runID: "r1", failure: .unversioned),
            "the active-run query must report the same typed failure; got \(String(describing: fromActive))"
        )
    }

    @Test("a seed this build wrote and something damaged is reported differently")
    func malformedCurrentSeedIsItsOwnFailure() throws {
        let url = try Fixtures.scratchPath(name: "damaged-seed.sqlite")
        defer { Fixtures.cleanUp(url) }

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // Version present and current, payload missing a required field. Of the three
        // ways a seed can be unreadable this is the only one that is a bug, and it must
        // not be reported as the clean cut.
        let damaged = #"{"formatVersion":1,"providerInstanceID":"pi1","modelID":"deepseek-chat"}"#
        try plantSeed(damaged, forRun: "r1", in: store)

        let failure = readFailure { _ = try store.run(id: "r1") }
        #expect(
            failure as? ZenAgent.PersistenceError
                == .unreadableRequestConfigSeed(runID: "r1", failure: .malformedCurrentVersion(1)),
            "expected a malformed-current failure rather than the unversioned one; got \(String(describing: failure))"
        )
    }

    @Test("an unknown format version is named, not treated as corruption")
    func unsupportedVersionIsItsOwnFailure() throws {
        let url = try Fixtures.scratchPath(name: "future-seed.sqlite")
        defer { Fixtures.cleanUp(url) }

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        // A version this build does not know. The payload body is never reached, so what
        // it contains does not matter - which is the point of checking the version first.
        try plantSeed(#"{"formatVersion":99,"anything":"at all"}"#, forRun: "r1", in: store)

        let failure = readFailure { _ = try store.run(id: "r1") }
        #expect(
            failure as? ZenAgent.PersistenceError
                == .unreadableRequestConfigSeed(runID: "r1", failure: .unsupportedVersion(99)),
            "a version this build does not understand must be named; got \(String(describing: failure))"
        )
    }

    @Test("a readable seed still reads")
    func readableSeedStillReads() throws {
        // The counterpart to the three above. A failure path that swallowed the ordinary
        // one would leave every other assertion in this file passing for the wrong reason.
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))

        let run = try store.run(id: "r1")
        #expect(run?.id == "r1")
        #expect(run?.requestConfigSeed.formatVersion == RequestConfigSeed.currentFormatVersion)
        #expect(try store.activeParentRuns(inConversation: "c1").count == 1)
    }

    @Test("v8SubmissionIndexUpgradesOldRunsAndRejectsDuplicateIDs")
    func v8SubmissionIndexUpgradesOldRunsAndRejectsDuplicateIDs() throws {
        let url = try Fixtures.scratchPath(name: "submission-identity-v8.sqlite")
        defer { Fixtures.cleanUp(url) }

        let before = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: v7Migrator())
        )
        var oldCommit = Fixtures.send(
            conversationID: "old-submission-conversation",
            messageID: "old-submission-message",
            runID: "old-submission-run",
            runState: .completed
        )
        oldCommit.run.endReason = .completed
        let seedData = try JSONEncoder().encode(oldCommit.run.requestConfigSeed)
        let rawSeed = String(decoding: seedData, as: UTF8.self)
        let legacyCommit = oldCommit
        try before.database.write { db in
            try legacyCommit.conversation.insert(db)
            try legacyCommit.message.insert(db)
            for part in legacyCommit.parts {
                try part.insert(db)
            }
            try db.execute(
                sql: """
                    INSERT INTO agentRun (
                        id, conversationID, kind, parentRunID, state, endReason,
                        recoveryAction, suspendReason, triggerMessageID, responseMessageID,
                        retryOfRunID, requestConfigSeed, executionSnapshot, createdAt,
                        updatedAt, activeSlot
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    legacyCommit.run.id,
                    legacyCommit.run.conversationID,
                    legacyCommit.run.kind.rawValue,
                    legacyCommit.run.parentRunID,
                    legacyCommit.run.state.rawValue,
                    legacyCommit.run.endReason?.rawValue,
                    legacyCommit.run.recoveryAction?.rawValue,
                    legacyCommit.run.suspendReason?.rawValue,
                    legacyCommit.run.triggerMessageID,
                    legacyCommit.run.responseMessageID,
                    legacyCommit.run.retryOfRunID,
                    rawSeed,
                    legacyCommit.run.executionSnapshot,
                    legacyCommit.run.createdAt,
                    legacyCommit.run.updatedAt,
                    legacyCommit.run.activeSlot,
                ]
            )
        }

        let after = PersistenceStore(
            database: try ZenDatabase.open(at: url.path(), migrator: currentMigrator())
        )
        #expect(try after.run(id: "old-submission-run")?.submissionID == nil)
        #expect(try after.run(id: "old-submission-run")?.submissionDigest == nil)
        #expect(try after.database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: ["agentRun_by_submission_id"]
            ) != nil
        })

        var first = Fixtures.send(
            conversationID: "new-submission-conversation",
            messageID: "new-submission-message",
            runID: "new-submission-run"
        )
        first.run.submissionID = "same-submission"
        first.run.submissionDigest = "digest-one"
        try after.commitUserTurnAndCreateParentRun(first)
        #expect(try after.run(id: "new-submission-run")?.submissionID == "same-submission")
        #expect(try after.run(id: "new-submission-run")?.submissionDigest == "digest-one")

        var duplicate = first.run
        duplicate.id = "duplicate-submission-run"
        duplicate.state = .completed
        duplicate.endReason = .completed
        duplicate.activeSlot = nil
        let duplicateRun = duplicate
        var duplicateRejected = false
        do {
            try after.database.write { db in try duplicateRun.insert(db) }
        } catch {
            duplicateRejected = true
        }
        #expect(duplicateRejected)
    }
}

/// Raised to interrupt a migration partway. Distinct from any other test's error type so
/// a failure here cannot be confused with a different injected failure.
struct MigrationInterruptedInTest: Error {}
