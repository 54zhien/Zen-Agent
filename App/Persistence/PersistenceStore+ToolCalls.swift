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
