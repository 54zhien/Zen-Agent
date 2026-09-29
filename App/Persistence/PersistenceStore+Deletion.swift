import Foundation
import GRDB

struct PendingCardDeletion: Equatable, Sendable {
    let conversationID: String
    let deadline: Date
}

/// The conversation deletion lifecycle.
///
///     visible → pendingDeletion → (undo → visible | finalize → finalizedDeletion)
///
/// Three states rather than a flag, because the undo window needs a state where the
/// conversation is gone from ordinary listing but its body is entirely intact. Undo
/// that returns an empty shell is the failure this shape exists to make impossible.
extension PersistenceStore {
    static let cardUndoWindow: TimeInterval = 10

    func beginCardDeletion(conversationID: String, at now: Date = Date()) throws -> PendingCardDeletion {
        let pending = PendingCardDeletion(conversationID: conversationID,
            deadline: now.addingTimeInterval(Self.cardUndoWindow))
        try beginDeletion(conversationID: conversationID, at: now, deadline: pending.deadline)
        return pending
    }

    func pendingCardDeletion(id: String) throws -> PendingCardDeletion? {
        try database.read { db in
            guard let deadline = try Date.fetchOne(db, sql: """
                SELECT deletion.deadlineAt FROM conversationDeletionDeadline AS deletion
                JOIN conversation ON conversation.id = deletion.conversationID
                WHERE deletion.conversationID = ? AND conversation.lifecycle = ?
                """, arguments: [id, ConversationLifecycle.pendingDeletion.rawValue]) else { return nil }
            return PendingCardDeletion(conversationID: id, deadline: deadline)
        }
    }

    /// Keyset page for cold-start expiry recovery. Only intent metadata crosses
    /// this boundary; no Message, Part, or file body is materialized.
    func pendingCardDeletionPage(after cursor: PendingCardDeletion? = nil,
                                 limit: Int = 50) throws -> [PendingCardDeletion] {
        try database.read { db in
            let count = min(50, max(1, limit))
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(db, sql: """
                    SELECT deletion.conversationID, deletion.deadlineAt
                    FROM conversationDeletionDeadline AS deletion
                    JOIN conversation ON conversation.id = deletion.conversationID
                    WHERE conversation.lifecycle = ?
                      AND (deletion.deadlineAt > ? OR
                           (deletion.deadlineAt = ? AND deletion.conversationID > ?))
                    ORDER BY deletion.deadlineAt, deletion.conversationID LIMIT ?
                    """, arguments: [ConversationLifecycle.pendingDeletion.rawValue,
                        cursor.deadline, cursor.deadline, cursor.conversationID, count])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT deletion.conversationID, deletion.deadlineAt
                    FROM conversationDeletionDeadline AS deletion
                    JOIN conversation ON conversation.id = deletion.conversationID
                    WHERE conversation.lifecycle = ?
                    ORDER BY deletion.deadlineAt, deletion.conversationID LIMIT ?
                    """, arguments: [ConversationLifecycle.pendingDeletion.rawValue, count])
            }
            return rows.map { PendingCardDeletion(conversationID: $0["conversationID"],
                deadline: $0["deadlineAt"]) }
        }
    }

    func undoCardDeletion(conversationID: String, at now: Date = Date()) throws {
        try database.write { db in
            try undoDeletion(conversationID: conversationID, at: now,
                requiresCardIntent: true, in: db)
        }
    }

    /// The UI may use this only while it still owns the original continuous
    /// timer, or after a recovered item receives an explicit restore choice.
    /// A wall-clock jump must not turn a live Undo into a refused transaction.
    func restoreCardDeletionWithoutWallDeadline(conversationID: String,
                                                at now: Date = Date()) throws {
        try database.write { db in
            try undoDeletion(conversationID: conversationID, at: now,
                requiresCardIntent: true, ignoreCardDeadline: true, in: db)
        }
    }

    /// Explicit recovery choice. Both the Card intent and pending lifecycle are
    /// checked in the same transaction that removes the body.
    func confirmRecoveredCardDeletion(conversationID: String, at now: Date = Date()) throws {
        try database.write { db in
            guard try Date.fetchOne(db, sql: """
                SELECT deletion.deadlineAt FROM conversationDeletionDeadline AS deletion
                JOIN conversation ON conversation.id = deletion.conversationID
                WHERE deletion.conversationID = ? AND conversation.lifecycle = ?
                """, arguments: [conversationID, ConversationLifecycle.pendingDeletion.rawValue]) != nil else {
                throw PersistenceError.invalidTransition("No recovered Card Delete to confirm")
            }
            try finalizeDeletion(conversationID: conversationID, at: now, in: db)
        }
    }

    func finalizeExpiredCardDeletion(conversationID: String, at now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard let deadline = try Date.fetchOne(db, sql: """
                SELECT deletion.deadlineAt FROM conversationDeletionDeadline AS deletion
                JOIN conversation ON conversation.id = deletion.conversationID
                WHERE deletion.conversationID = ? AND conversation.lifecycle = ?
                """, arguments: [conversationID, ConversationLifecycle.pendingDeletion.rawValue]),
                now >= deadline else { return false }
            try finalizeDeletion(conversationID: conversationID, at: now, in: db)
            return true
        }
    }

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
    /// The active-slot check shares this transaction with the lifecycle update, so
    /// a new Parent Run cannot slip in after the caller's Stop and before deletion.
    func beginDeletion(conversationID: String, at now: Date = Date()) throws {
        try beginDeletion(conversationID: conversationID, at: now, deadline: nil)
    }

    private func beginDeletion(conversationID: String, at now: Date, deadline: Date?) throws {
        try database.write { db in
            let conversation = try requireConversation(conversationID, in: db)
            guard conversation.lifecycle == .visible else {
                throw PersistenceError.invalidLifecycleTransition(
                    expected: .visible, actual: conversation.lifecycle
                )
            }
            guard try String.fetchOne(db,
                sql: "SELECT id FROM agentRun WHERE activeSlot = ? LIMIT 1",
                arguments: [conversationID]) == nil else {
                throw PersistenceError.invalidTransition("Active Parent Run must settle before deletion")
            }
            try db.execute(
                sql: "UPDATE conversation SET lifecycle = ?, updatedAt = ? WHERE id = ?",
                arguments: [ConversationLifecycle.pendingDeletion.rawValue, now, conversationID]
            )
            if let deadline {
                try db.execute(sql: """
                    INSERT INTO conversationDeletionDeadline(conversationID, deadlineAt) VALUES (?, ?)
                    """, arguments: [conversationID, deadline])
            }
        }
    }

    /// Puts it back. The body was never touched, so there is nothing to restore.
    ///
    /// Guarded on the current state rather than simply writing `visible` back.
    /// Finalising is one-way: without this guard, undoing a finalised deletion would
    /// flip the flag to visible over a body that no longer exists — a conversation that
    /// claims to be there and has nothing in it. The undo window is a state, not a
    /// boolean you can set back.
    func undoDeletion(conversationID: String, at now: Date = Date()) throws {
        try database.write { db in
            try undoDeletion(conversationID: conversationID, at: now,
                requiresCardIntent: false, in: db)
        }
    }

    private func undoDeletion(conversationID: String, at now: Date,
                              requiresCardIntent: Bool, ignoreCardDeadline: Bool = false,
                              in db: Database) throws {
        let conversation = try requireConversation(conversationID, in: db)
        guard conversation.lifecycle == .pendingDeletion else {
            throw PersistenceError.invalidLifecycleTransition(
                expected: .pendingDeletion, actual: conversation.lifecycle)
        }
        let hasDeadlineTable = try db.tableExists("conversationDeletionDeadline")
        var deadline: Date?
        if hasDeadlineTable {
            deadline = try Date.fetchOne(db, sql: """
                SELECT deadlineAt FROM conversationDeletionDeadline WHERE conversationID = ?
                """, arguments: [conversationID])
        }
        if requiresCardIntent && deadline == nil {
            throw PersistenceError.invalidTransition("No pending Card Delete to undo")
        }
        if let deadline, now >= deadline, !ignoreCardDeadline {
            throw PersistenceError.invalidTransition("Card Delete Undo deadline has expired")
        }
        try db.execute(sql: "UPDATE conversation SET lifecycle = ?, updatedAt = ? WHERE id = ?",
            arguments: [ConversationLifecycle.visible.rawValue, now, conversationID])
        if hasDeadlineTable {
            try db.execute(sql: "DELETE FROM conversationDeletionDeadline WHERE conversationID = ?",
                arguments: [conversationID])
        }
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
            try finalizeDeletion(conversationID: conversationID, at: now, in: db)
        }
    }

    private func finalizeDeletion(conversationID: String, at now: Date,
                                  in db: Database) throws {
            // Refused before any write — a refused finalise must not even write
            // tombstones. Keep the lifecycle check in this transaction; nesting
            // another `database.write` here would violate GRDB's write boundary.
            let conversation = try requireConversation(conversationID, in: db)
            switch conversation.lifecycle {
            case .pendingDeletion:
                break // the one state from which finalising does anything
            case .finalizedDeletion:
                // A retry must not throw forever: the outcome is already known, and
                // "finalising twice must not fail" is the tombstone's contract below.
                return
            case .visible:
                // This would skip the undo window and burn a body undo still claims
                // it can bring back. Refused.
                throw PersistenceError.invalidLifecycleTransition(
                    expected: .pendingDeletion,
                    actual: conversation.lifecycle
                )
            }

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
                    // Nothing is passed in, deliberately: this record outlives the
                    // conversation, and `call.executionIntent` is that conversation's
                    // body. See `destinationFingerprint()` for where the rule belongs.
                    destinationFingerprint: Self.destinationFingerprint(),
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
                sql: "DELETE FROM conversationSoulBinding WHERE conversationID = ?",
                arguments: [conversationID]
            )

            try db.execute(
                sql: "UPDATE conversation SET lifecycle = ?, updatedAt = ? WHERE id = ?",
                arguments: [ConversationLifecycle.finalizedDeletion.rawValue, now, conversationID]
            )
            if try db.tableExists("conversationDeletionDeadline") {
                try db.execute(sql: "DELETE FROM conversationDeletionDeadline WHERE conversationID = ?",
                    arguments: [conversationID])
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

    /// Fetches the conversation a lifecycle mutation names. A mutation on a
    /// conversation that does not exist is a caller bug, not a no-op.
    private func requireConversation(
        _ conversationID: String,
        in db: Database
    ) throws -> ConversationRecord {
        guard let conversation = try ConversationRecord.fetchOne(db, key: conversationID) else {
            throw PersistenceError.conversationNotFound(conversationID)
        }
        return conversation
    }

    /// What a tombstone records about where the effect landed. Today: `unknownDestination`.
    ///
    /// A reserved position, not a derivation. Which part of a frozen intent identifies
    /// the destination is the Tool Runtime's rule to make — it owns that intent's shape,
    /// and it does not exist yet. Inventing one here would hand the Runtime a format it
    /// never chose; a hash would be no better, since "did that mail go out?" is not a
    /// question a user can answer with one. The value that claims nothing is the only
    /// honest one available.
    ///
    /// It takes no argument, and that is the point rather than an oversight. A tombstone
    /// has to outlive its conversation, and the intent is that conversation's body — the
    /// part the user deleted. A parameter is the single step that lets the body be copied
    /// in, so there is none: an intent reaching a tombstone is not discouraged here, it
    /// is unwritable. When the Runtime lands, this takes *its* parsed value, never the
    /// raw body, so this stays the one place that changes.
    static let unknownDestination = "unknown"

    static func destinationFingerprint() -> String {
        unknownDestination
    }
}
