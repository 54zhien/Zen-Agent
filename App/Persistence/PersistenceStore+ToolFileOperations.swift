import Foundation
import GRDB

extension PersistenceStore {
    func toolFileOperation(callID: String, attempt: Int, intentBinding: String) throws -> ToolFileOperationRecord? {
        try database.read { db in
            guard let receipt = try ToolFileOperationRecord.fetchOne(db, key: callID) else { return nil }
            guard let call = try ToolCallRecord.fetchOne(db, key: callID), call.attempt == attempt,
                  let json = call.executionIntent, receipt.attempt == attempt,
                  ToolPolicyIdentity.equals(receipt.intentBinding, intentBinding),
                  ToolPolicyIdentity.equals(ToolIntentBinding.make(json), intentBinding) else {
                throw ToolIntentFailure.dependenciesChanged
            }
            return receipt
        }
    }

    func requireDispatchedFileMutation(_ mutation: ManagedFileToolMutation) throws {
        try database.read { try Self.validateFileMutation(mutation, in: $0) }
    }

    func commitToolFileWrite(_ mutation: ManagedFileToolMutation, asset: FileAssetRecord,
        version: FileAssetVersionRecord, checkCancellation: @Sendable () throws -> Void) throws {
        try database.write { db in
            try checkCancellation()
            try Self.validateFileMutation(mutation, in: db)
            guard mutation.kind != .delete, ToolPolicyIdentity.equals(asset.id, mutation.assetID),
                  ToolPolicyIdentity.equals(version.id, mutation.versionID), ToolPolicyIdentity.equals(version.assetID, asset.id),
                  ToolPolicyIdentity.equals(version.contentFingerprint, mutation.fingerprint) else { throw ToolIntentFailure.dependenciesChanged }
            switch mutation.kind {
            case .create:
                guard try FileAssetRecord.fetchOne(db, key: asset.id) == nil else { throw ToolIntentFailure.dependenciesChanged }
                try asset.insert(db)
                try version.insert(db)
            case .modify:
                guard let current = try FileAssetRecord.fetchOne(db, key: asset.id),
                      mutation.expectedVersionID.map({ ToolPolicyIdentity.equals(current.currentVersionID, $0) }) == true else { throw ToolIntentFailure.dependenciesChanged }
                try version.insert(db)
                try db.execute(sql: """
                    UPDATE fileAsset SET currentVersionID = ?, updatedAt = ?
                    WHERE id = ? AND currentVersionID = ?
                    """, arguments: [version.id, asset.updatedAt, asset.id, mutation.expectedVersionID])
                guard db.changesCount == 1 else { throw ToolIntentFailure.dependenciesChanged }
            case .delete: throw ToolIntentFailure.invalidArguments
            }
            try Self.insertFileReceipt(mutation, asset: asset, version: version, in: db)
            try checkCancellation()
        }
    }

    func commitToolFileRemoval(_ mutation: ManagedFileToolMutation,
        checkCancellation: @Sendable () throws -> Void) throws -> Bool {
        try database.write { db in
            try checkCancellation()
            try Self.validateFileMutation(mutation, in: db)
            guard mutation.kind == .delete,
                  let asset = try FileAssetRecord.fetchOne(db, key: mutation.assetID),
                  mutation.expectedVersionID.map({ ToolPolicyIdentity.equals(asset.currentVersionID, $0) }) == true,
                  let version = try FileAssetVersionRecord.fetchOne(db, key: mutation.versionID),
                  ToolPolicyIdentity.equals(version.assetID, asset.id), ToolPolicyIdentity.equals(version.contentFingerprint, mutation.fingerprint) else {
                throw ToolIntentFailure.dependenciesChanged
            }
            guard try !Self.fileAssetIsReferenced(asset.id, excludingToolCallID: mutation.callID, in: db) else { return false }
            try FileAssetRecord.deleteOne(db, key: asset.id)
            try Self.insertFileReceipt(mutation, asset: asset, version: version, in: db)
            try checkCancellation()
            return true
        }
    }

    /// Called only after querying a durable receipt; it never performs the file operation.
    func confirmToolFileOutcome(callID: String, attempt: Int, intentBinding: String,
                                result: ToolExecutionResult, at now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: callID),
                  call.attempt == attempt, let json = call.executionIntent,
                  ToolPolicyIdentity.equals(ToolIntentBinding.make(json), intentBinding),
                  call.state == .dispatched || call.state == .indeterminate,
                  let run = try AgentRunRecord.fetchOne(db, key: call.agentRunID), run.state == .recovering,
                  let receipt = try ToolFileOperationRecord.fetchOne(db, key: callID),
                  receipt.attempt == attempt, ToolPolicyIdentity.equals(receipt.intentBinding, intentBinding) else { return false }
            try db.execute(sql: """
                UPDATE toolCall SET state = 'succeeded', failureReason = NULL, updatedAt = ?
                WHERE id = ? AND attempt = ? AND state IN ('dispatched','indeterminate')
                """, arguments: [now, callID, attempt])
            guard db.changesCount == 1 else { return false }
            try ToolResultRecord(toolCallID: callID, payload: result.content, createdAt: now,
                kind: result.kind, failureCode: result.failure).insert(db)
            return true
        }
    }

    /// Shared by Workspace deletion and Tool deletion. Pending Tool reads/writes
    /// retain their exact source while the owning Run remains active.
    static func fileAssetIsReferenced(_ assetID: String, excludingToolCallID: String? = nil,
                                     in db: Database) throws -> Bool {
        let messages = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM messageAttachment WHERE assetID = ? OR versionID IN
            (SELECT id FROM fileAssetVersion WHERE assetID = ?)
            """, arguments: [assetID, assetID]) ?? 0
        if messages > 0 { return true }
        let calls = try ToolCallRecord.fetchAll(db, sql: """
            SELECT toolCall.* FROM toolCall JOIN agentRun ON agentRun.id = toolCall.agentRunID
            WHERE agentRun.state NOT IN ('completed','failed','cancelled')
            """)
        for call in calls where !call.state.isTerminal {
            if let excluded = excludingToolCallID, ToolPolicyIdentity.equals(call.id, excluded) { continue }
            guard let json = call.executionIntent, let intent = try? ToolIntentCodec.decodeForDisplay(json) else { continue }
            if case .file(let id, _, _) = intent.resourceScope, ToolPolicyIdentity.equals(id, assetID) { return true }
            if intent.toolID == "files", intent.policyAction?.actionID == "create",
               intent.resourceScope == .target(assetID) { return true }
        }
        return false
    }

    private static func validateFileMutation(_ mutation: ManagedFileToolMutation, in db: Database) throws {
        guard let call = try ToolCallRecord.fetchOne(db, key: mutation.callID),
              call.state == .dispatched, call.attempt == mutation.attempt,
              let json = call.executionIntent, ToolPolicyIdentity.equals(ToolIntentBinding.make(json), mutation.intentBinding),
              let intent = try? ToolIntentCodec.decodeForDisplay(json), intent.toolID == "files",
              intent.policyAction?.actionID == mutation.kind.rawValue,
              let args = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              (args["assetID"] as? String).map({ ToolPolicyIdentity.equals($0, mutation.assetID) }) == true else { throw ToolIntentFailure.dependenciesChanged }
        if mutation.kind == .create {
            guard ToolPolicyIdentity.equals(mutation.assetID, "tool-\(call.id)"), ToolPolicyIdentity.equals(mutation.versionID, "tool-version-\(call.id)"),
                  intent.resourceScope == .target(mutation.assetID) else { throw ToolIntentFailure.dependenciesChanged }
        } else {
            guard case .file(let asset, let version, let fingerprint) = intent.resourceScope,
                  ToolPolicyIdentity.equals(asset, mutation.assetID), mutation.expectedVersionID.map({ ToolPolicyIdentity.equals(version, $0) }) == true,
                  let current = try FileAssetRecord.fetchOne(db, key: asset), ToolPolicyIdentity.equals(current.currentVersionID, version),
                  let original = try FileAssetVersionRecord.fetchOne(db, key: version),
                  ToolPolicyIdentity.equals(original.assetID, asset), ToolPolicyIdentity.equals(original.contentFingerprint, fingerprint) else { throw ToolIntentFailure.dependenciesChanged }
            if mutation.kind == .delete {
                guard ToolPolicyIdentity.equals(mutation.versionID, version), ToolPolicyIdentity.equals(mutation.fingerprint, fingerprint) else { throw ToolIntentFailure.dependenciesChanged }
            }
        }
        if mutation.kind != .delete {
            guard (args["newVersionID"] as? String).map({ ToolPolicyIdentity.equals($0, mutation.versionID) }) == true,
                  (args["newFingerprint"] as? String).map({ ToolPolicyIdentity.equals($0, mutation.fingerprint) }) == true else { throw ToolIntentFailure.dependenciesChanged }
        }
    }

    private static func insertFileReceipt(_ mutation: ManagedFileToolMutation, asset: FileAssetRecord,
                                         version: FileAssetVersionRecord, in db: Database) throws {
        let result = try ManagedFileToolReference.result(assetID: asset.id, versionID: version.id,
            fingerprint: version.contentFingerprint, reason: mutation.kind == .delete ? "removedFromWorkspace" : mutation.kind.rawValue)
        try ToolFileOperationRecord(toolCallID: mutation.callID, attempt: mutation.attempt,
            intentBinding: mutation.intentBinding, kind: mutation.kind, assetID: asset.id,
            versionID: version.id, fingerprint: version.contentFingerprint, byteCount: version.byteCount,
            resultJSON: result.content).insert(db)
    }
}
