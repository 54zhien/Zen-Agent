import Foundation
import GRDB

extension PersistenceStore {
    /// Stores trusted approval facts only. It neither approves the original call
    /// nor replaces the evaluator/pre-dispatch checks reserved for S6-04.
    func issueToolGrant(id: String, grant: ToolScopedGrant, expectedPolicy: ToolPolicySnapshot) throws -> Bool {
        try database.write { db in
            try Self.issueToolGrant(in: db, id: id, grant: grant, expectedPolicy: expectedPolicy)
        }
    }

    static func issueToolGrant(in db: Database, id: String, grant: ToolScopedGrant,
                               expectedPolicy: ToolPolicySnapshot) throws -> Bool {
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
        let current = try Self.readToolPolicy(db, toolID: grant.toolID, actionID: grant.actionID,
            descriptorRevision: grant.descriptorRevision)
        guard current == expectedPolicy, current.mode != .deny,
              try ToolGrantRecord.fetchOne(db, key: id) == nil,
              let call = try ToolCallRecord.fetchOne(db, key: approval.toolCallID),
              ToolPolicyIdentity.equals(call.agentRunID, approval.agentRunID),
              ToolPolicyIdentity.equals(call.action, grant.toolID),
              let run = try AgentRunRecord.fetchOne(db, key: call.agentRunID),
              let conversation = try ConversationRecord.fetchOne(db, key: run.conversationID),
              conversation.lifecycle == .visible else { return false }
        switch run.kind {
        case .parent:
            guard run.parentRunID == nil, run.state.isActive else { return false }
            switch call.state {
            case .validated, .waitingForApproval, .waitingForSystemPermissionConsent, .approved, .prepared: break
            default: return false
            }
        case .child:
            guard call.state == .waitingForApproval,
                  run.state.isActive,
                  run.state != .stopping,
                  run.recoveryAction != .invalidate,
                  grant.subject == .run(run.id),
                  case .once = grant.kind,
                  let owner = try Self.linkedDelegationParent(for: run, db: db),
                  owner.parent.conversationID == run.conversationID,
                  conversation.id == owner.parent.conversationID,
                  Self.parentCanAuthorizeLinkedChild(owner.parent, delegationCall: owner.delegationCall)
            else { return false }
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
        // Anchor an implicit default's revision with its first issuance so
        // the first explicit revision update can revoke that authority too.
        // A rejected issuance creates no policy row; either insert failing
        // rolls back both facts in this same transaction.
        try db.execute(sql: """
            INSERT INTO toolGlobalPolicy (toolID, actionID, descriptorRevision, mode, revocationEpoch)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(toolID, actionID) DO NOTHING
            """, arguments: [current.toolID, current.actionID, current.descriptorRevision,
                Self.policyName(current.mode), Int64(current.revocationEpoch)])
        // Binding derivation belongs to trusted Runtime, not JSON/UI input.
        // The schema stores no second copy of the executable arguments.
        try ToolGrantRecord(id: id, grant: grant, approval: approval, conversationID: run.conversationID).insert(db)
        return true
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

    static func linkedDelegationParent(
        for child: AgentRunRecord,
        db: Database
    ) throws -> (parent: AgentRunRecord, delegationCall: ToolCallRecord)? {
        guard child.kind == .child,
              let parentRunID = child.parentRunID,
              let parentToolCallID = try String.fetchOne(db, sql: """
                SELECT parentToolCallID FROM delegatedChildRun WHERE childRunID = ?
                """, arguments: [child.id]),
              let delegationCall = try ToolCallRecord.fetchOne(db, key: parentToolCallID),
              delegationCall.action == SubagentDelegationTool.toolID,
              ToolPolicyIdentity.equals(delegationCall.agentRunID, parentRunID),
              let parent = try AgentRunRecord.fetchOne(db, key: parentRunID),
              parent.kind == .parent,
              parent.parentRunID == nil,
              ToolPolicyIdentity.equals(parent.conversationID, child.conversationID)
        else { return nil }
        return (parent, delegationCall)
    }

    static func parentCanAuthorizeLinkedChild(
        _ parent: AgentRunRecord,
        delegationCall: ToolCallRecord
    ) -> Bool {
        switch parent.state {
        case .executingTools:
            return parent.recoveryAction == nil && delegationCall.state == .dispatched
        case .recovering:
            return parent.recoveryAction == .resume
                && (delegationCall.state == .dispatched || delegationCall.state == .indeterminate)
        default:
            return false
        }
    }
}
