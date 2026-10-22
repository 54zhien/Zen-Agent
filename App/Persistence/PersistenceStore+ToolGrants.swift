import Foundation
import GRDB

extension PersistenceStore {
    /// Stores trusted approval facts only. It neither approves the original call
    /// nor replaces the evaluator/pre-dispatch checks reserved for S6-04.
    func issueToolGrant(id: String, grant: ToolScopedGrant, expectedPolicy: ToolPolicySnapshot) throws -> Bool {
        guard [id, grant.toolID, grant.actionID, grant.descriptorRevision].allSatisfy(ToolPolicyIdentity.isValid),
              grant.subject.isValid, grant.resource.isValid, grant.destination.isValid,
              grant.validity == .active, grant.revocationEpoch <= UInt64(Int64.max),
              let approval = grant.issuedFor,
              [approval.toolCallID, approval.agentRunID, approval.intentBinding].allSatisfy(ToolPolicyIdentity.isValid),
              ToolPolicyIdentity.equals(expectedPolicy.toolID, grant.toolID),
              ToolPolicyIdentity.equals(expectedPolicy.actionID, grant.actionID),
              ToolPolicyIdentity.equals(expectedPolicy.descriptorRevision, grant.descriptorRevision),
              expectedPolicy.revocationEpoch == grant.revocationEpoch else { return false }
        if case .once(let call, let run, let binding) = grant.kind {
            guard ToolPolicyIdentity.equals(call, approval.toolCallID),
                  ToolPolicyIdentity.equals(run, approval.agentRunID),
                  ToolPolicyIdentity.equals(binding, approval.intentBinding) else { return false }
        }
        return try database.write { db in
            let current = try Self.readToolPolicy(db, toolID: grant.toolID, actionID: grant.actionID,
                descriptorRevision: grant.descriptorRevision)
            guard current == expectedPolicy, current.mode != .deny,
                  try ToolGrantRecord.fetchOne(db, key: id) == nil,
                  let call = try ToolCallRecord.fetchOne(db, key: approval.toolCallID),
                  ToolPolicyIdentity.equals(call.agentRunID, approval.agentRunID),
                  ToolPolicyIdentity.equals(call.action, grant.toolID),
                  let run = try AgentRunRecord.fetchOne(db, key: call.agentRunID),
                  run.kind == .parent, run.parentRunID == nil, run.state.isActive,
                  let conversation = try ConversationRecord.fetchOne(db, key: run.conversationID),
                  conversation.lifecycle == .visible else { return false }
            // Match the existing approval owner. Child approval/ancestor expiry
            // remains unavailable until the later Subagent stage implements it.
            switch call.state {
            case .validated, .waitingForApproval, .waitingForSystemPermissionConsent, .approved, .prepared: break
            default: return false
            }
            switch grant.subject {
            case .parentConversation(let value):
                guard ToolPolicyIdentity.equals(value, run.conversationID) else { return false }
            case .run(let value):
                guard ToolPolicyIdentity.equals(value, run.id) else { return false }
            }
            guard let json = call.executionIntent, let intent = try? ToolIntentCodec.decodeForDisplay(json),
                  intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
                  ToolPolicyIdentity.equals(intent.toolID, grant.toolID),
                  ToolPolicyIdentity.equals(intent.descriptorRevision, grant.descriptorRevision),
                  let action = intent.policyAction, action.isKnown,
                  ToolPolicyIdentity.equals(action.toolID, grant.toolID),
                  ToolPolicyIdentity.equals(action.actionID, grant.actionID),
                  ToolPolicyIdentity.equals(action.descriptorRevision, grant.descriptorRevision),
                  intent.resourceScope == grant.resource, intent.destinationScope == grant.destination,
                  action.resourceRequirement.accepts(grant.resource),
                  action.egressRequirement.accepts(grant.destination) else { return false }
            if case .conversation = grant.kind, !action.allowsConversationGrant { return false }
            // Binding derivation belongs to trusted Runtime, not JSON/UI input.
            // The schema stores no second copy of the executable arguments.
            try ToolGrantRecord(id: id, grant: grant, approval: approval, conversationID: run.conversationID).insert(db)
            return true
        }
    }

    func toolGrant(id: String) throws -> ToolScopedGrant? {
        try database.read { db in try ToolGrantRecord.fetchOne(db, key: id)?.snapshot() }
    }

    /// Keep the issuance IDs on recovery so revocation can address the original
    /// row, without deriving identity from a displayed scope or pane.
    func toolGrants(subject: ToolGrantSubject) throws -> [(id: String, grant: ToolScopedGrant)] {
        let kind: String
        let value: String
        switch subject {
        case .parentConversation(let id): kind = "parentConversation"; value = id
        case .run(let id): kind = "run"; value = id
        }
        return try database.read { db in
            try ToolGrantRecord.filter(Column("subjectKind") == kind)
                .filter(Column("subjectID") == value).order(Column("id")).fetchAll(db)
                .map { (id: $0.id, grant: try $0.snapshot()) }
        }
    }

    @discardableResult
    func revokeToolGrant(id: String) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE toolScopedGrant SET validity = 'revoked' WHERE id = ? AND validity = 'active'",
                arguments: [id])
            return db.changesCount == 1
        }
    }
}
