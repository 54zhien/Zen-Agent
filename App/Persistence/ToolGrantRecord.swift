import Foundation
import GRDB

/// Storage identity and immutable issuance facts. Only validity is changed by
/// revocation/lifecycle transactions; there is no second executable payload.
struct ToolGrantRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "toolScopedGrant"
    let id: String
    let subjectKind: String
    let subjectID: String
    let toolID: String
    let actionID: String
    let descriptorRevision: String
    let resource: String
    let destination: String
    let kind: String
    let validity: String
    let revocationEpoch: Int64
    let issuedToolCallID: String
    let issuedRunID: String
    let issuedIntentBinding: String
    let originConversationID: String

    init(id: String, grant: ToolScopedGrant, approval: ToolGrantApprovalBinding, conversationID: String) throws {
        self.id = id
        switch grant.subject {
        case .parentConversation(let value): subjectKind = "parentConversation"; subjectID = value
        case .run(let value): subjectKind = "run"; subjectID = value
        }
        toolID = grant.toolID
        actionID = grant.actionID
        descriptorRevision = grant.descriptorRevision
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        resource = String(decoding: try encoder.encode(grant.resource), as: UTF8.self)
        destination = String(decoding: try encoder.encode(grant.destination), as: UTF8.self)
        switch grant.kind {
        case .once: kind = "once"
        case .conversation: kind = "conversation"
        }
        validity = "active"
        guard let epoch = Int64(exactly: grant.revocationEpoch) else {
            throw PersistenceError.invalidTransition("Unrepresentable grant revocation epoch")
        }
        revocationEpoch = epoch
        issuedToolCallID = approval.toolCallID
        issuedRunID = approval.agentRunID
        issuedIntentBinding = approval.intentBinding
        originConversationID = conversationID
    }

    func snapshot() throws -> ToolScopedGrant {
        guard [id, subjectID, toolID, actionID, descriptorRevision, issuedToolCallID,
               issuedRunID, issuedIntentBinding, originConversationID].allSatisfy(ToolPolicyIdentity.isValid),
              revocationEpoch >= 0 else {
            throw PersistenceError.invalidTransition("Unreadable stored tool grant")
        }
        let subject: ToolGrantSubject
        switch subjectKind {
        case "parentConversation":
            guard ToolPolicyIdentity.equals(subjectID, originConversationID) else {
                throw PersistenceError.invalidTransition("Unreadable stored grant subject")
            }
            subject = .parentConversation(subjectID)
        case "run":
            guard ToolPolicyIdentity.equals(subjectID, issuedRunID) else {
                throw PersistenceError.invalidTransition("Unreadable stored grant subject")
            }
            subject = .run(subjectID)
        default: throw PersistenceError.invalidTransition("Unreadable stored grant subject")
        }
        let grantKind: ToolGrantKind
        switch kind {
        case "once": grantKind = .once(toolCallID: issuedToolCallID, agentRunID: issuedRunID, intentBinding: issuedIntentBinding)
        case "conversation": grantKind = .conversation
        default: throw PersistenceError.invalidTransition("Unreadable stored grant kind")
        }
        let grantValidity: ToolGrantValidity
        switch validity {
        case "active": grantValidity = .active
        case "revoked": grantValidity = .revoked
        case "consumed": grantValidity = .consumed
        default: throw PersistenceError.invalidTransition("Unreadable stored grant validity")
        }
        let decoder = JSONDecoder()
        let resourceScope = try decoder.decode(ToolResourceScope.self, from: Data(resource.utf8))
        let destinationScope = try decoder.decode(ToolDestinationScope.self, from: Data(destination.utf8))
        guard resourceScope.isValid, destinationScope.isValid else {
            throw PersistenceError.invalidTransition("Unreadable stored grant scope")
        }
        return ToolScopedGrant(kind: grantKind, subject: subject, toolID: toolID, actionID: actionID,
            descriptorRevision: descriptorRevision, resource: resourceScope, destination: destinationScope,
            validity: grantValidity, revocationEpoch: UInt64(revocationEpoch),
            issuedFor: ToolGrantApprovalBinding(toolCallID: issuedToolCallID, agentRunID: issuedRunID,
                intentBinding: issuedIntentBinding))
    }
}
