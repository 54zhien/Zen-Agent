import Foundation
import GRDB

extension PersistenceStore {

    /// Compare-and-set transition for the Run lifecycle.
    ///
    /// The expected state is part of the SQL predicate, not only an in-memory check.
    /// That makes a late Runtime owner fail without being able to overwrite a newer
    /// state. Derived active-slot maintenance stays in the same transaction as the
    /// state and lifecycle metadata.
    func transitionRun(
        id: String,
        expectedState: RunState,
        to state: RunState,
        endReason: EndReason? = nil,
        recoveryAction: RecoveryAction? = nil,
        suspendReason: SuspendReason? = nil,
        at now: Date = Date()
    ) throws {
        guard RunStateMachine.canTransition(from: expectedState, to: state) else {
            throw PersistenceError.invalidTransition(
                "run cannot transition from \(expectedState.rawValue) to \(state.rawValue)"
            )
        }

        try Self.validateLifecycleMetadata(
            state: state,
            endReason: endReason,
            recoveryAction: recoveryAction,
            suspendReason: suspendReason
        )

        try database.write { db in
            guard let current = try AgentRunRecord.fetchOne(db, key: id) else {
                throw PersistenceError.runNotFound(id)
            }

            var next = current
            next.state = state
            next.endReason = endReason
            next.recoveryAction = recoveryAction
            next.suspendReason = suspendReason
            next.updatedAt = now
            next.activeSlot = Self.activeSlot(for: next)

            let arguments: [(any DatabaseValueConvertible)?] = [
                next.state.rawValue,
                next.endReason?.rawValue,
                next.recoveryAction?.rawValue,
                next.suspendReason?.rawValue,
                next.activeSlot,
                next.updatedAt,
                id,
                expectedState.rawValue,
            ]

            try db.execute(
                sql: """
                    UPDATE agentRun
                    SET state = ?, endReason = ?, recoveryAction = ?, suspendReason = ?,
                        activeSlot = ?, updatedAt = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: StatementArguments(arguments)
            )

            guard db.changesCount == 1 else {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "agentRun",
                    id: id,
                    precondition: expectedState.rawValue,
                    notFound: PersistenceError.runNotFound(id)
                )
            }
        }
    }

    /// Lazily creates and binds the one Assistant response for a Run.
    ///
    /// The existing binding is checked before the terminal guard so a completed Run
    /// can still be read idempotently, while a terminal Run that never produced
    /// Assistant output cannot acquire a placeholder response after the fact.
    func ensureAssistantResponse(
        forRunID runID: String,
        messageID: String,
        at now: Date = Date()
    ) throws -> MessageRecord {
        do {
            return try database.write { db in
                guard let run = try AgentRunRecord.fetchOne(db, key: runID) else {
                    throw PersistenceError.runNotFound(runID)
                }

                if let responseID = run.responseMessageID {
                    guard let existing = try MessageRecord.fetchOne(db, key: responseID) else {
                        throw PersistenceError.invalidTransition(
                            "run \(runID) points to missing response message \(responseID)"
                        )
                    }
                    guard existing.conversationID == run.conversationID else {
                        throw PersistenceError.invalidTransition(
                            "run \(runID) response message belongs to another conversation"
                        )
                    }
                    return existing
                }

                guard !run.state.isTerminal else {
                    throw PersistenceError.invalidTransition(
                        "terminal run \(runID) cannot create its first assistant response"
                    )
                }

                let nextSequence = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(MAX(sequence), -1) + 1
                        FROM message
                        WHERE conversationID = ?
                        """,
                    arguments: [run.conversationID]
                ) ?? 0

                let message = MessageRecord(
                    id: messageID,
                    conversationID: run.conversationID,
                    role: .assistant,
                    sequence: nextSequence,
                    createdAt: now
                )
                try message.insert(db)

                try db.execute(
                    sql: """
                        UPDATE agentRun
                        SET responseMessageID = ?, updatedAt = ?
                        WHERE id = ? AND responseMessageID IS NULL
                        """,
                    arguments: [messageID, now, runID]
                )

                guard db.changesCount == 1 else {
                    throw PersistenceError.invalidTransition(
                        "run \(runID) response binding was changed while creating a message"
                    )
                }
                return message
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }

    private static func validateLifecycleMetadata(
        state: RunState,
        endReason: EndReason?,
        recoveryAction: RecoveryAction?,
        suspendReason: SuspendReason?
    ) throws {
        if state.isTerminal {
            guard endReason != nil else {
                throw PersistenceError.invalidTransition(
                    "terminal state \(state.rawValue) requires an end reason"
                )
            }
            guard recoveryAction == nil, suspendReason == nil else {
                throw PersistenceError.invalidTransition(
                    "terminal state \(state.rawValue) cannot carry recovery or suspend metadata"
                )
            }
            return
        }

        guard endReason == nil else {
            throw PersistenceError.invalidTransition(
                "non-terminal state \(state.rawValue) cannot carry an end reason"
            )
        }

        switch state {
        case .suspended:
            guard suspendReason != nil, recoveryAction != nil else {
                throw PersistenceError.invalidTransition(
                    "suspended state requires suspend reason and recovery action"
                )
            }
        case .recovering:
            guard recoveryAction != nil else {
                throw PersistenceError.invalidTransition(
                    "recovering state requires a recovery action"
                )
            }
            guard suspendReason == nil else {
                throw PersistenceError.invalidTransition(
                    "recovering state cannot carry a suspend reason"
                )
            }
        default:
            guard recoveryAction == nil, suspendReason == nil else {
                throw PersistenceError.invalidTransition(
                    "active state \(state.rawValue) cannot carry recovery or suspend metadata"
                )
            }
        }
    }
}
