import Foundation
import GRDB

extension PersistenceStore {
    /// A different stored revision is returned intact so the evaluator can
    /// reject it, rather than silently replacing old authority with defaults.
    func toolPolicy(toolID: String, actionID: String, descriptorRevision: String) throws -> ToolPolicySnapshot {
        try database.read { db in
            try Self.readToolPolicy(db, toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision)
        }
    }

    @discardableResult
    func setToolPolicy(toolID: String, actionID: String, descriptorRevision: String,
                       mode: ToolPersistentPolicy) throws -> ToolPolicySnapshot {
        try database.write { db in
            let previous = try Self.readToolPolicy(db, toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision)
            let tightens = Self.policyRank(mode) > Self.policyRank(previous.mode)
                || !ToolPolicyIdentity.equals(descriptorRevision, previous.descriptorRevision)
            let (epoch, overflow) = Int64(previous.revocationEpoch).addingReportingOverflow(tightens ? 1 : 0)
            guard !overflow else { throw PersistenceError.invalidTransition("Tool policy revocation epoch exhausted") }
            try db.execute(sql: """
                INSERT INTO toolGlobalPolicy (toolID, actionID, descriptorRevision, mode, revocationEpoch)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(toolID, actionID) DO UPDATE SET
                    descriptorRevision = excluded.descriptorRevision,
                    mode = excluded.mode, revocationEpoch = excluded.revocationEpoch
                """, arguments: [toolID, actionID, descriptorRevision, Self.policyName(mode), epoch])
            // Widening never lowers this floor or revives a revoked issuance.
            // The policy and every affected grant change in the same transaction.
            if tightens {
                try db.execute(sql: """
                    UPDATE toolScopedGrant SET validity = 'revoked'
                    WHERE toolID = ? AND actionID = ? AND validity = 'active'
                    """, arguments: [toolID, actionID])
            }
            return ToolPolicySnapshot(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision,
                mode: mode, revocationEpoch: UInt64(epoch))
        }
    }

    static func readToolPolicy(_ db: Database, toolID: String, actionID: String,
                               descriptorRevision: String) throws -> ToolPolicySnapshot {
        guard [toolID, actionID, descriptorRevision].allSatisfy(ToolPolicyIdentity.isValid) else {
            throw PersistenceError.invalidTransition("Invalid tool policy identity")
        }
        guard let row = try StoredToolPolicy.fetchOne(db, sql: """
            SELECT * FROM toolGlobalPolicy WHERE toolID = ? AND actionID = ?
            """, arguments: [toolID, actionID]) else {
            return ToolPolicySnapshot(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision,
                mode: .askEveryTime, revocationEpoch: 0)
        }
        let mode: ToolPersistentPolicy
        switch row.mode {
        case "alwaysAllow": mode = .alwaysAllow
        case "askEveryTime": mode = .askEveryTime
        case "deny": mode = .deny
        default: throw PersistenceError.invalidTransition("Unreadable stored tool policy")
        }
        guard row.revocationEpoch >= 0, ToolPolicyIdentity.isValid(row.descriptorRevision) else {
            throw PersistenceError.invalidTransition("Unreadable stored tool policy")
        }
        return ToolPolicySnapshot(toolID: row.toolID, actionID: row.actionID, descriptorRevision: row.descriptorRevision,
            mode: mode, revocationEpoch: UInt64(row.revocationEpoch))
    }

    private static func policyName(_ mode: ToolPersistentPolicy) -> String {
        switch mode {
        case .alwaysAllow: "alwaysAllow"
        case .askEveryTime: "askEveryTime"
        case .deny: "deny"
        }
    }

    private static func policyRank(_ mode: ToolPersistentPolicy) -> Int {
        switch mode {
        case .alwaysAllow: 0
        case .askEveryTime: 1
        case .deny: 2
        }
    }
}

private struct StoredToolPolicy: Decodable, FetchableRecord {
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let mode: String
    let revocationEpoch: Int64
}
