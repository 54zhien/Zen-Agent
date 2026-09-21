import Foundation
import GRDB

/// Tool call persistence — the minimum needed to prove the crash-window invariant.
///
/// **Not a Tool Runtime.** There is no registry, no policy, no approval flow and no
/// executor here. What is here is the storage
/// side of one question: after a crash, can recovery tell a call that provably never
/// left the process from one that might have reached the outside world?
///
/// The answer rests on the dispatch marker being committed *before* the external call
/// is attempted, which is why `markDispatched` exists as its own step rather than
/// being folded into "execute".
extension PersistenceStore {

    func createToolCall(_ toolCall: ToolCallRecord) throws {
        try database.write { db in
            try toolCall.insert(db)
        }
    }

    /// Atomically creates a model-visible rejection for a call that never reached a
    /// registered executor. This is intentionally separate from `complete`: unknown
    /// tools remain an error at the direct ToolRuntime boundary, while a provider batch
    /// still needs a durable result before it can continue.
    func createRejectedToolCall(
        _ toolCall: ToolCallRecord,
        result: ToolResultRecord
    ) throws {
        guard toolCall.state == .rejected, result.toolCallID == toolCall.id else {
            throw PersistenceError.invalidTransition(
                "createRejectedToolCall requires a rejected call and matching result"
            )
        }
        try database.write { db in
            try toolCall.insert(db)
            try result.insert(db)
        }
    }

    /// Stops a call without inventing a successful outcome. A call that has not crossed
    /// the dispatch marker becomes `notExecuted`; one that has crossed it becomes
    /// `indeterminate` because cancellation cannot prove whether its side effect landed.
    func settleToolCallForCancellation(id: String, at now: Date = Date()) throws {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: id) else {
                throw PersistenceError.toolCallNotFound(id)
            }

            let nextState: ToolCallState?
            switch call.state {
            case .validated, .waitingForApproval, .waitingForSystemPermissionConsent,
                 .approved, .prepared:
                nextState = .notExecuted
            case .dispatched:
                nextState = .indeterminate
            case .succeeded, .failed, .rejected, .cancelled, .notExecuted, .indeterminate:
                nextState = nil
            }

            guard let nextState else { return }
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ?",
                arguments: [nextState.rawValue, now, id]
            )
        }
    }

    /// Marks a dispatched call indeterminate when its executor stops before reporting
    /// whether the external side effect landed.
    func markToolCallIndeterminate(id: String, at now: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE toolCall
                    SET state = ?, updatedAt = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    ToolCallState.indeterminate.rawValue,
                    now,
                    id,
                    ToolCallState.dispatched.rawValue,
                ]
            )
            if db.changesCount == 0 {
                guard let call = try ToolCallRecord.fetchOne(db, key: id) else {
                    throw PersistenceError.toolCallNotFound(id)
                }
                guard call.state == .indeterminate else {
                    throw PersistenceError.invalidTransition(
                        "only a dispatched tool call can become indeterminate"
                    )
                }
            }
        }
    }

    func toolResult(toolCallID: String) throws -> ToolResultRecord? {
        try database.read { db in
            try ToolResultRecord.fetchOne(db, key: toolCallID)
        }
    }

    /// Moves an approved call into the prepared state without opening the dispatch
    /// window. The dispatch marker remains a separate transaction boundary.
    func markToolCallPrepared(id: String, at now: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state = ?",
                arguments: [
                    ToolCallState.prepared.rawValue,
                    now,
                    id,
                    ToolCallState.approved.rawValue,
                ]
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "state = approved",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
        }
    }

    /// Records an approval decision on the existing call. Approval never creates a
    /// replacement call and never crosses the dispatch boundary by itself.
    func approveToolCall(id: String, at now: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state = ?",
                arguments: [
                    ToolCallState.approved.rawValue,
                    now,
                    id,
                    ToolCallState.waitingForApproval.rawValue,
                ]
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "state = waitingForApproval",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
        }
    }

    /// Settles an approval rejection and its model-visible result in one transaction.
    func rejectWaitingForApprovalToolCall(
        id: String,
        result: ToolResultRecord,
        at now: Date = Date()
    ) throws {
        guard result.toolCallID == id else {
            throw PersistenceError.invalidTransition(
                "rejectWaitingForApprovalToolCall result belongs to \(result.toolCallID), not \(id)"
            )
        }

        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state = ?",
                arguments: [
                    ToolCallState.rejected.rawValue,
                    now,
                    id,
                    ToolCallState.waitingForApproval.rawValue,
                ]
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "state = waitingForApproval",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
            try result.insert(db)
        }
    }

    /// Commits the marker that says an external call is about to be attempted.
    ///
    /// Called **before** the call, never after. Committing it afterwards would leave a
    /// window where the call happened but nothing recorded it, and recovery would
    /// cheerfully run it a second time. The cost of committing it first is the
    /// opposite error — a call that never happened being reported as indeterminate —
    /// and that is the direction the design deliberately errs in.
    func markToolCallDispatched(id: String, at now: Date = Date()) throws {
        // Derived from the disposition rather than listed: the marker may only be
        // committed from a state where nothing left the process, and a state that
        // later stops meaning that must stop being a valid source without a change
        // here.
        let allowed = ToolCallState.allCases
            .filter { $0.recoveryDisposition == .mayDispatch }
            .map(\.rawValue)
        let questionMarks = databaseQuestionMarks(count: allowed.count)

        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state IN (\(questionMarks))",
                arguments: StatementArguments(
                    [ToolCallState.dispatched.rawValue, now, id]
                        + allowed.map { $0 as (any DatabaseValueConvertible)? }
                )
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "a state that may still be dispatched (\(allowed.joined(separator: ", ")))",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
        }
    }

    func finishToolCall(id: String, state: ToolCallState, at now: Date = Date()) throws {
        guard state.isTerminal else {
            throw PersistenceError.invalidTransition(
                "finishToolCall requires a terminal state; got \(state.rawValue)"
            )
        }

        // Derived from the disposition rather than listed: the only calls whose
        // outcome can be finished are the ones that may have reached the outside
        // world. A call that never dispatched cannot jump straight to a terminal
        // state without the marker — that is the window the marker exists to close.
        let allowed = ToolCallState.allCases
            .filter { $0.recoveryDisposition == .mustReportIndeterminate }
            .map(\.rawValue)
        let questionMarks = databaseQuestionMarks(count: allowed.count)

        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state IN (\(questionMarks))",
                arguments: StatementArguments(
                    [state.rawValue, now, id]
                        + allowed.map { $0 as (any DatabaseValueConvertible)? }
                )
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "dispatched or indeterminate",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
        }
    }

    /// Completes only the dispatched attempt that the executor was handed.
    ///
    /// This is deliberately narrower than `finishToolCall`: recovery may turn a
    /// dispatched call into `indeterminate`, and a late executor callback must not be
    /// able to overwrite that conclusion. Inserting the result shares the same database
    /// transaction as the compare-and-set state change.
    func finishDispatchedToolCall(
        id: String,
        expectedAttempt: Int,
        state: ToolCallState,
        result: ToolResultRecord?,
        at now: Date = Date()
    ) throws {
        guard state.isTerminal else {
            throw PersistenceError.invalidTransition(
                "finishDispatchedToolCall requires a terminal state; got \(state.rawValue)"
            )
        }
        if let result, result.toolCallID != id {
            throw PersistenceError.invalidTransition(
                "finishDispatchedToolCall result belongs to \(result.toolCallID), not \(id)"
            )
        }

        try database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ?, updatedAt = ? WHERE id = ? AND state = 'dispatched' AND attempt = ?",
                arguments: [
                    state.rawValue,
                    now,
                    id,
                    expectedAttempt,
                ]
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "toolCall",
                    id: id,
                    precondition: "state = dispatched and attempt = \(expectedAttempt)",
                    notFound: PersistenceError.toolCallNotFound(id)
                )
            }
            if let result {
                try result.insert(db)
            }
        }
    }

    func toolCall(id: String) throws -> ToolCallRecord? {
        try database.read { db in
            try ToolCallRecord.fetchOne(db, key: id)
        }
    }

    func toolCalls(inRun runID: String) throws -> [ToolCallRecord] {
        try database.read { db in
            try ToolCallRecord
                .filter(Column("agentRunID") == runID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Calls recovery must act on, with what it is allowed to do.
    ///
    /// Pairing the state with its disposition here rather than leaving the caller to
    /// switch on states means the mapping exists once. A caller that decided for itself
    /// that `dispatched` "probably didn't happen" would be re-deriving the rule, and
    /// deriving it wrong.
    func toolCallsNeedingRecovery(inRun runID: String) throws -> [(call: ToolCallRecord, disposition: ToolRecoveryDisposition)] {
        try toolCalls(inRun: runID)
            .map { ($0, $0.state.recoveryDisposition) }
            .filter { $0.1 != .settled }
    }
}
