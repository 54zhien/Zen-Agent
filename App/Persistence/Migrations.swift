import Foundation
import GRDB

/// Schema migrations, numbered from v1.
///
/// Deliberately started now rather than "when there is an old database to migrate
/// from". The second schema change would otherwise be the moment a migration system
/// gets retrofitted under time pressure, and that is exactly when it goes wrong.
/// One migration is enough to establish the shape.
///
/// GRDB runs each migration inside a transaction, so an interrupted migration rolls
/// back whole. That property was verified in the Stage 0 spike before this code was
/// written — see `Docs/ADR/0001-persistence-engine.md`.
enum Migrations {

    /// The production migrator.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        return migrator
    }

    /// Registered separately so a test can compose them with a migration of its own and
    /// exercise the upgrade path over a real store.
    static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_create_initial_schema") { db in
            try createConversation(db)
            try createMessage(db)
            try createMessagePart(db)
            try createAgentRun(db)
            try createToolCall(db)
            try createOperationTombstone(db)
        }
    }

    /// Adds the per-request identity a streaming event is checked against.
    ///
    /// A separate migration rather than an edit to v1, even though nothing has shipped.
    /// Editing an applied migration is only safe while no store has ever run it, and
    /// that condition expires silently: the moment someone holds a Stage 0 store, the
    /// edit stops being safe and nothing says so. A real v2 also means the migration
    /// tests exercise the actual upgrade path rather than a synthetic one.
    static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_add_agent_step") { db in
            try db.create(table: "agentStep") { t in
                t.column("stepID", .text).notNull()
                t.column("runID", .text).notNull().references("agentRun", onDelete: .cascade)
                t.column("sequence", .integer).notNull()
                t.column("attempt", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                // Composite key: the database enforces one row per attempt, rather than
                // trusting callers not to record the same attempt twice.
                t.primaryKey(["stepID", "attempt"])
            }
            try db.create(
                index: "agentStep_by_run",
                on: "agentStep",
                columns: ["runID", "sequence", "attempt"]
            )
        }
    }

    /// Adds the non-secret half of the credential boundary.
    ///
    /// **Nothing in this table is a secret.** It holds an opaque id, a counter, an
    /// optional opaque fingerprint and a status. The secret itself lives in the
    /// Keychain, and `SecretValue` is not `Codable`, so there is no way to put one here
    /// even by mistake.
    ///
    /// The counter is the point: it changes when the binding changes *identity*, which
    /// is not visible in the id. A logout or an account change leaves the id identical,
    /// so a suspended run comparing only the id would carry on against a different
    /// principal.
    static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_add_credential_binding") { db in
            try db.create(table: "credentialBinding") { t in
                t.column("credentialID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("bindingGeneration", .integer).notNull()
                t.column("principalFingerprint", .text)
                t.column("status", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["credentialID", "kind"])
            }
        }
    }

    /// Adds user-added Provider connections.
    ///
    /// The credential columns hold a **reference** — an opaque id and its kind — and
    /// nothing else. There is no column a secret could go in, and `SecretValue` is not
    /// `Codable`, so there is no way to make one.
    ///
    /// `credentialID` is nullable on purpose. An instance whose credential was removed
    /// is still a valid instance: the user's endpoint and provider choice outlive the
    /// secret, and deleting the secret must not delete their configuration
    /// (`安全与权限.md:279` requires the opposite direction of care too — removing an
    /// instance must not orphan a credential another instance still shares).
    static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_add_provider_instance") { db in
            try db.create(table: "providerInstance") { t in
                t.primaryKey("id", .text)
                t.column("providerID", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("baseURL", .text)
                t.column("configRevision", .text).notNull()
                // A reference, never material. Both columns move together: a credential
                // id without its kind is not a reference.
                t.column("credentialID", .text)
                t.column("credentialKind", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    // MARK: - Tables

    private static func createConversation(_ db: Database) throws {
        try db.create(table: "conversation") { t in
            t.primaryKey("id", .text)
            t.column("title", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("userActiveAt", .datetime).notNull()
            t.column("pinned", .boolean).notNull().defaults(to: false)
            // visible | pendingDeletion | finalizedDeletion
            //
            // Kept as a column rather than a delete flag because the undo window has
            // to hold the body intact — a "deleted" boolean cannot express the state
            // where the conversation is hidden but fully recoverable.
            t.column("lifecycle", .text).notNull().defaults(to: "visible")
        }
    }

    private static func createMessage(_ db: Database) throws {
        try db.create(table: "message") { t in
            t.primaryKey("id", .text)
            t.column("conversationID", .text).notNull().references("conversation", onDelete: .cascade)
            // user | assistant | system
            t.column("role", .text).notNull()
            t.column("sequence", .integer).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "message_by_conversation", on: "message", columns: ["conversationID", "sequence"])
    }

    private static func createMessagePart(_ db: Database) throws {
        try db.create(table: "messagePart") { t in
            t.primaryKey("id", .text)
            t.column("messageID", .text).notNull().references("message", onDelete: .cascade)
            t.column("sequence", .integer).notNull()
            // text | reasoning | toolCall | toolResult
            t.column("kind", .text).notNull()
            // pending | streaming | completed | failed | cancelled
            t.column("state", .text).notNull()
            t.column("payload", .text).notNull()
        }
        try db.create(index: "messagePart_by_message", on: "messagePart", columns: ["messageID", "sequence"])
    }

    private static func createAgentRun(_ db: Database) throws {
        try db.create(table: "agentRun") { t in
            t.primaryKey("id", .text)
            t.column("conversationID", .text).notNull().references("conversation", onDelete: .cascade)
            // parent | child
            t.column("kind", .text).notNull()
            // Child runs point at their parent; the reverse is never needed.
            t.column("parentRunID", .text).references("agentRun", onDelete: .cascade)

            t.column("state", .text).notNull()
            // EndReason and RecoveryAction are separate from state, and from each
            // other — a run that has ended has a reason, a run that needs handling has
            // an action. Collapsing them is the mistake the blueprint warns about.
            t.column("endReason", .text)
            t.column("recoveryAction", .text)
            t.column("suspendReason", .text)

            // The three links that make a Run explainable: what triggered it, what it
            // produced, and what it is a retry of. `responseMessageID` stays null when
            // the provider failed before producing anything — no placeholder message.
            t.column("triggerMessageID", .text).references("message", onDelete: .setNull)
            t.column("responseMessageID", .text).references("message", onDelete: .setNull)
            t.column("retryOfRunID", .text).references("agentRun", onDelete: .setNull)

            // Frozen at send commit; the execution snapshot is filled during preparing
            // and never rewrites the seed.
            t.column("requestConfigSeed", .text).notNull()
            t.column("executionSnapshot", .text)

            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()

            // The active-slot mechanism, verified in the spike before this schema
            // existed: equal to the conversation id while the run is active, NULL once
            // it reaches a terminal state. See the index below.
            t.column("activeSlot", .text)
        }

        try db.create(index: "agentRun_by_conversation", on: "agentRun", columns: ["conversationID", "createdAt"])

        // The invariant the ADR turns on: at most one active parent run per
        // conversation, enforced by the database rather than by application discipline.
        //
        // Three details that all matter:
        //
        // - `activeSlot IS NOT NULL` makes it *conditional* uniqueness. SQL treats
        //   NULLs as distinct, so any number of terminal runs coexist while only one
        //   may hold the slot. The spike confirmed SwiftData's #Unique cannot express
        //   this — it upserts and silently overwrites the incumbent.
        // - `kind = 'parent'` keeps child runs out of the slot. A child run is active
        //   too, but the per-conversation slot belongs to the parent; without this
        //   clause the first subagent would collide with its own parent.
        // - Written as raw SQL because GRDB's index builder has no condition clause.
        try db.execute(sql: """
            CREATE UNIQUE INDEX agentRun_one_active_parent_per_conversation
            ON agentRun (activeSlot)
            WHERE activeSlot IS NOT NULL AND kind = 'parent'
            """)
    }

    private static func createToolCall(_ db: Database) throws {
        try db.create(table: "toolCall") { t in
            t.primaryKey("id", .text)
            t.column("agentRunID", .text).notNull().references("agentRun", onDelete: .cascade)
            t.column("action", .text).notNull()
            // validated | waitingForApproval | waitingForSystemPermissionConsent |
            // approved | prepared | dispatched | succeeded | failed | rejected |
            // cancelled | notExecuted | indeterminate
            //
            // `prepared` and `dispatched` are separate on purpose: the first means the
            // external call has not been attempted, the second means it might have
            // been. That distinction is the only basis for deciding, after a crash,
            // whether a call may be retried or must be reported as indeterminate.
            t.column("state", .text).notNull()
            // Normalised and frozen before approval; the executor consumes this same
            // value, so an approval cannot be redirected to a different target.
            t.column("executionIntent", .text)
            t.column("attempt", .integer).notNull().defaults(to: 1)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(index: "toolCall_by_run", on: "toolCall", columns: ["agentRunID", "createdAt"])
    }

    private static func createOperationTombstone(_ db: Database) throws {
        try db.create(table: "operationTombstone") { t in
            t.primaryKey("toolCallID", .text)
            t.column("action", .text).notNull()
            t.column("destinationFingerprint", .text).notNull()
            t.column("attempt", .integer).notNull()
            t.column("status", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }

        // No foreign key to `conversation` or `toolCall`, and that is the design.
        //
        // A tombstone exists because the thing that owned it is gone: it records an
        // external operation whose outcome is unknown, after the conversation holding
        // it has been finalised and its body erased. Any cascade path would delete the
        // only record of a side effect that may have actually happened. The spike
        // verified both engines can express this; GRDB does it by simply not declaring
        // the relationship.
    }
}
