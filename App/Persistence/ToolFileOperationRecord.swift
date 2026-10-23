import Foundation
import GRDB

/// Immutable proof of a logical file operation committed with its metadata.
/// It deliberately carries neither file contents nor executable arguments.
struct ToolFileOperationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "toolFileOperation"
    let toolCallID: String
    let attempt: Int
    let intentBinding: String
    let kind: ManagedFileToolMutationKind
    let assetID: String
    let versionID: String
    let fingerprint: String
    let byteCount: Int64
    let resultJSON: String

    var descriptor: ManagedFileDescriptor {
        ManagedFileDescriptor(assetID: assetID, versionID: versionID, fingerprint: fingerprint,
            byteCount: byteCount, mediaType: "text/plain", displayName: "Managed file")
    }

    func matches(_ mutation: ManagedFileToolMutation) -> Bool {
        attempt == mutation.attempt && kind == mutation.kind
            && ToolPolicyIdentity.equals(toolCallID, mutation.callID)
            && ToolPolicyIdentity.equals(intentBinding, mutation.intentBinding)
            && ToolPolicyIdentity.equals(assetID, mutation.assetID)
            && ToolPolicyIdentity.equals(versionID, mutation.versionID)
            && ToolPolicyIdentity.equals(fingerprint, mutation.fingerprint)
    }
}
