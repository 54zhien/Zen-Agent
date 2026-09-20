import Foundation
import GRDB

/// The conversation deletion lifecycle.
///
///     visible → pendingDeletion → (undo → visible | finalize → finalizedDeletion)
///
/// Three states rather than a flag, because the undo window needs a state where the
/// conversation is gone from ordinary listing but its body is entirely intact. Undo
/// that returns an empty shell is the failure this shape exists to make impossible.
extension PersistenceStore {

    /// Conversations in ordinary listing. Pending-deletion ones are absent.
    func visibleConversations() throws -> [ConversationRecord] {
        try database.read { db in
            try ConversationRecord
                .filter(Column("lifecycle") == ConversationLifecycle.visible.rawValue)
                .order(Column("userActiveAt").desc)
                .fetchAll(db)
        }
    }

    func conversationLifecycle(id: String) throws -> ConversationLifecycle? {
        try conversation(id: id)?.lifecycle
    }

    /// Commits the delete. Hides the conversation; keeps everything.
    func beginDeletion(conversationID: String, at now: Date = Date()) throws {
        try transition(from: .visible, to: .pendingDeletion, conversationID: conversationID, at: now)
    }

    /// Puts it back. The body was never touched, so there is nothing to restore.
    ///
    /// Guarded on the current state rather than simply writing `visible` back.
    /// Finalising is one-way: without this guard, undoing a finalised deletion would
    /// flip the flag to visible over a body that no longer exists — a conversation that
    /// claims to be there and has nothing in it. The undo window is a state, not a
    /// boolean you can set back.
    func undoDeletion(conversationID: String, at now: Date = Date()) throws {
        try transition(from: .pendingDeletion, to: .visible, conversationID: conversationID, at: now)
    }

    /// The point of no return: the body goes, and what must survive, survives.
    ///
    /// Ordering inside the transaction is the whole design. Tombstones are written
    /// **before** anything is deleted — a crash between the two would otherwise leave
    /// an external operation that may have happened with no record that it did. Doing
    /// it the other way round is a silent data loss that only shows up as a duplicated
    /// side effect later.
    func finalizeDeletion(conversationID: String, at now: Date = Date()) throws {
        try database.write { db in
            // Derived from the disposition rather than listed: a state that later
            // comes to mean "may have happened" must start producing tombstones
            // without a change here.
            let mustReport = ToolCallState.allCases
                .filter { $0.recoveryDisposition == .mustReportIndeterminate }
                .map(\.rawValue)
            let questionMarks = databaseQuestionMarks(count: mustReport.count)

            let mustReportCalls = try ToolCallRecord.fetchAll(db, sql: """
                SELECT toolCall.* FROM toolCall
                JOIN agentRun ON agentRun.id = toolCall.agentRunID
                WHERE agentRun.conversationID = ? AND toolCall.state IN (\(questionMarks))
                """, arguments: StatementArguments([conversationID] + mustReport))

            for call in mustReportCalls {
                let tombstone = OperationTombstoneRecord(
                    toolCallID: call.id,
                    action: call.action,
                    // Whatever identifies where the effect landed. The intent is the
                    // frozen one the executor was given, not anything readable now.
                    destinationFingerprint: Self.destinationFingerprint(from: call.executionIntent),
                    attempt: call.attempt,
                    status: call.state.rawValue,
                    createdAt: now
                )
                // Upsert: finalising twice must not fail, and must not lose the
                // original record either.
                try tombstone.upsert(db)
            }

            // Body first: message parts follow their message by cascade.
            try db.execute(sql: "DELETE FROM message WHERE conversationID = ?", arguments: [conversationID])
            try db.execute(sql: """
                DELETE FROM toolCall WHERE agentRunID IN (SELECT id FROM agentRun WHERE conversationID = ?)
                """, arguments: [conversationID])
            try db.execute(sql: "DELETE FROM agentRun WHERE conversationID = ?", arguments: [conversationID])

            try db.execute(
                sql: "UPDATE conversation SET lifecycle = ?, updatedAt = ? WHERE id = ?",
                arguments: [ConversationLifecycle.finalizedDeletion.rawValue, now, conversationID]
            )
        }
    }

    // MARK: - Tombstones

    func tombstones() throws -> [OperationTombstoneRecord] {
        try database.read { db in
            try OperationTombstoneRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    func tombstone(toolCallID: String) throws -> OperationTombstoneRecord? {
        try database.read { db in
            try OperationTombstoneRecord.fetchOne(db, key: toolCallID)
        }
    }

    // MARK: - Internals

    /// Moves the lifecycle, refusing transitions the lifecycle does not have.
    ///
    /// Written as an explicit from/to pair so every transition has to name where it
    /// starts. A bare "set to X" cannot express that, and one of the two directions here
    /// is one-way.
    private func transition(
        from expected: ConversationLifecycle,
        to next: ConversationLifecycle,
        conversationID: String,
        at now: Date
    ) throws {
        try database.write { db in
            guard let conversation = try ConversationRecord.fetchOne(db, key: conversationID) else {
                throw PersistenceError.conversationNotFound(conversationID)
            }
            guard conversation.lifecycle == expected else {
                throw PersistenceError.invalidTransition(
                    "expected \(expected.rawValue) but the conversation is \(conversation.lifecycle.rawValue)"
                )
            }
            try db.execute(
                sql: "UPDATE conversation SET lifecycle = ?, updatedAt = ? WHERE id = ?",
                arguments: [next.rawValue, now, conversationID]
            )
        }
    }

    /// Best-effort extraction of the target identity from a frozen execution intent.
    ///
    /// Returns the raw intent when it cannot be read, rather than an empty string: a
    /// tombstone whose whole purpose is to identify an external operation must not
    /// quietly become unidentifiable. The shape of the intent belongs to the Tool
    /// Runtime, which does not exist yet — so this deliberately errs toward keeping
    /// too much rather than too little.
    static func destinationFingerprint(from executionIntent: String?) -> String {
        guard let executionIntent, !executionIntent.isEmpty else { return "unknown" }
        return executionIntent
    }
}
