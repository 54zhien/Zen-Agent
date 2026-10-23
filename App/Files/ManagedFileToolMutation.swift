import Foundation

enum ManagedFileToolMutationKind: String, Codable, Sendable { case create, modify, delete }

/// A trusted projection of the original frozen call, not a second executable payload.
struct ManagedFileToolMutation: Sendable {
    let callID: String
    let attempt: Int
    let intentBinding: String
    let kind: ManagedFileToolMutationKind
    let assetID: String
    let versionID: String
    let expectedVersionID: String?
    let fingerprint: String
}

enum ManagedFileToolReference {
    static func result(assetID: String, versionID: String, fingerprint: String,
                       reason: String) throws -> ToolExecutionResult {
        ToolExecutionResult(content: try ToolArgumentJSON.normalizedObject([
            "kind": "managedFile", "assetID": assetID, "versionID": versionID,
            "fingerprint": fingerprint, "reason": reason
        ]), kind: .reference)
    }
}
