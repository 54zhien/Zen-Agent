import Foundation

/// The only JSON boundary for a `RunExecutionSnapshot`.
enum ExecutionSnapshotCodec {
    typealias FormatError = RunExecutionSnapshot.FormatError

    static func encode(_ snapshot: RunExecutionSnapshot) throws -> String {
        let data = try JSONEncoder().encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ encodedSnapshot: String) throws -> RunExecutionSnapshot {
        try JSONDecoder().decode(
            RunExecutionSnapshot.self,
            from: Data(encodedSnapshot.utf8)
        )
    }
}

extension PersistenceStore {
    /// Completes the one-way preparing boundary for a run.
    ///
    /// The state and NULL checks are repeated in the SQL predicate so a stale
    /// preparing owner cannot write after another owner has completed or advanced the
    /// run. The request seed is deliberately absent from the UPDATE: it was frozen by
    /// the atomic send commit and is not part of this later snapshot write.
    func completeExecutionSnapshot(
        runID: String,
        encodedSnapshot: String,
        at now: Date = Date()
    ) throws {
        try database.write { db in
            guard let run = try AgentRunRecord.fetchOne(db, key: runID) else {
                throw PersistenceError.runNotFound(runID)
            }
            guard run.state == .preparing else {
                throw PersistenceError.invalidTransition(
                    "run \(runID) must be preparing to complete its execution snapshot"
                )
            }
            guard run.executionSnapshot == nil else {
                throw PersistenceError.invalidTransition(
                    "run \(runID) execution snapshot is already complete"
                )
            }

            try db.execute(
                sql: """
                    UPDATE agentRun
                    SET executionSnapshot = ?, updatedAt = ?
                    WHERE id = ? AND state = ? AND executionSnapshot IS NULL
                    """,
                arguments: [
                    encodedSnapshot,
                    now,
                    runID,
                    RunState.preparing.rawValue,
                ]
            )

            guard db.changesCount == 1 else {
                guard let current = try AgentRunRecord.fetchOne(db, key: runID) else {
                    throw PersistenceError.runNotFound(runID)
                }
                if current.state != .preparing {
                    throw PersistenceError.invalidTransition(
                        "run \(runID) is no longer preparing"
                    )
                }
                if current.executionSnapshot != nil {
                    throw PersistenceError.invalidTransition(
                        "run \(runID) execution snapshot is already complete"
                    )
                }
                throw PersistenceError.invalidTransition(
                    "run \(runID) execution snapshot could not be completed"
                )
            }
        }
    }
}
