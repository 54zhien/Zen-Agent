import Foundation
import GRDB

extension PersistenceStore {
    /// Read identities without decoding request seeds. One damaged seed must not hide
    /// the other runs that still occupy active Parent slots.
    func activeParentRunIDs() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM agentRun WHERE activeSlot IS NOT NULL ORDER BY id"
            )
        }
    }

    /// Closes a taskless run and every open child record before releasing its slot.
    /// The single transaction also keeps a second launch from observing a terminal
    /// Run with an open Part or an unsettled side effect.
    func settleTasklessRun(
        id: String,
        expectedState: RunState,
        terminalState: RunState,
        endReason: EndReason,
        at now: Date = Date()
    ) throws {
        guard terminalState.isTerminal,
              RunStateMachine.canTransition(from: expectedState, to: terminalState)
        else {
            throw PersistenceError.invalidTransition("invalid taskless settlement")
        }

        try database.write { db in
            let actual = try String.fetchOne(
                db,
                sql: "SELECT state FROM agentRun WHERE id = ? AND activeSlot IS NOT NULL",
                arguments: [id]
            )
            guard actual == expectedState.rawValue else {
                throw PersistenceError.invalidTransition("taskless run state changed")
            }

            let partState: MessagePartState = terminalState == .cancelled ? .cancelled : .failed
            try db.execute(
                sql: """
                    UPDATE messagePart SET state = ?
                    WHERE messageID = (SELECT responseMessageID FROM agentRun WHERE id = ?)
                      AND state IN (?, ?)
                    """,
                arguments: [
                    partState.rawValue,
                    id,
                    MessagePartState.pending.rawValue,
                    MessagePartState.streaming.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE toolCall
                    SET state = CASE WHEN state = ? THEN ? ELSE ? END, updatedAt = ?
                    WHERE agentRunID = ? AND state IN (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    ToolCallState.dispatched.rawValue,
                    ToolCallState.indeterminate.rawValue,
                    ToolCallState.notExecuted.rawValue,
                    now,
                    id,
                    ToolCallState.validated.rawValue,
                    ToolCallState.waitingForApproval.rawValue,
                    ToolCallState.waitingForSystemPermissionConsent.rawValue,
                    ToolCallState.approved.rawValue,
                    ToolCallState.prepared.rawValue,
                    ToolCallState.dispatched.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE agentRun
                    SET state = ?, endReason = ?, recoveryAction = NULL,
                        suspendReason = NULL, activeSlot = NULL, updatedAt = ?
                    WHERE id = ? AND state = ? AND activeSlot IS NOT NULL
                    """,
                arguments: [
                    terminalState.rawValue,
                    endReason.rawValue,
                    now,
                    id,
                    expectedState.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw PersistenceError.invalidTransition("taskless run settlement lost ownership")
            }
        }
    }
}
