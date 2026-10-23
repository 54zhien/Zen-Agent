import GRDB

/// Immutable admission facts. Original ToolCall still owns execution state and
/// frozen JSON; this row cannot independently dispatch or replay anything.
struct ToolCallPolicyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "toolCallPolicy"
    let toolCallID: String
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let mode: String
    let revocationEpoch: Int64
    let disposition: String
    let intentBinding: String

    init(toolCallID: String, policy: ToolPolicySnapshot,
         disposition: ToolPolicyAdmissionDisposition, intentBinding: String) throws {
        self.toolCallID = toolCallID
        toolID = policy.toolID; actionID = policy.actionID; descriptorRevision = policy.descriptorRevision
        mode = PersistenceStore.policyName(policy.mode)
        guard let epoch = Int64(exactly: policy.revocationEpoch) else {
            throw PersistenceError.invalidTransition("Unrepresentable admission epoch")
        }
        revocationEpoch = epoch
        self.disposition = switch disposition {
        case .allowed: "allowed"
        case .needsApproval: "needsApproval"
        case .denied: "denied"
        }
        self.intentBinding = intentBinding
    }

    func snapshot() throws -> (policy: ToolPolicySnapshot, admission: ToolPolicyAdmission) {
        guard [toolCallID, toolID, actionID, descriptorRevision, intentBinding].allSatisfy(ToolPolicyIdentity.isValid),
              revocationEpoch >= 0 else {
            throw PersistenceError.invalidTransition("Unreadable ToolCall admission")
        }
        let policyMode: ToolPersistentPolicy
        switch mode {
        case "alwaysAllow": policyMode = .alwaysAllow
        case "askEveryTime": policyMode = .askEveryTime
        case "deny": policyMode = .deny
        default: throw PersistenceError.invalidTransition("Unreadable ToolCall policy")
        }
        let admission: ToolPolicyAdmissionDisposition
        switch disposition {
        case "allowed": admission = .allowed
        case "needsApproval": admission = .needsApproval
        case "denied": admission = .denied
        default: throw PersistenceError.invalidTransition("Unreadable ToolCall admission")
        }
        return (ToolPolicySnapshot(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision,
                    mode: policyMode, revocationEpoch: UInt64(revocationEpoch)),
                ToolPolicyAdmission(disposition: admission, intentBinding: intentBinding))
    }
}
