import Foundation
import GRDB

extension PersistenceStore {
    func createToolCallWithPolicy(_ candidate: ToolCallRecord, descriptor: ToolDescriptor,
                                  safetyCap: ToolPolicySafetyCap, at now: Date) throws -> ToolCallRecord {
        try database.write { db in
            var call = candidate
            call.state = .validated
            try call.insert(db)
            return try Self.authorizeToolCall(db, call: call, descriptor: descriptor, safetyCap: safetyCap,
                checkedIntentBinding: candidate.executionIntent.map(ToolIntentBinding.make), operation: .creation, at: now)
        }
    }

    func reconcileToolCallPolicy(id: String, expectedAttempt: Int, descriptor: ToolDescriptor,
                                 safetyCap: ToolPolicySafetyCap, checkedIntentBinding: String,
                                 at now: Date) throws -> ToolCallRecord {
        try changeToolCallAuthorization(id: id, expectedAttempt: expectedAttempt, descriptor: descriptor,
            safetyCap: safetyCap, checkedIntentBinding: checkedIntentBinding, operation: .reconcile, at: now)
    }

    func approveToolCallWithPolicy(id: String, expectedAttempt: Int, descriptor: ToolDescriptor,
                                  safetyCap: ToolPolicySafetyCap, checkedIntentBinding: String,
                                  displayedIntentBinding: String?, at now: Date) throws -> ToolCallRecord {
        try changeToolCallAuthorization(id: id, expectedAttempt: expectedAttempt, descriptor: descriptor,
            safetyCap: safetyCap, checkedIntentBinding: checkedIntentBinding,
            operation: .approval(displayedIntentBinding), at: now)
    }

    /// The current policy/grants and original owner are read in the write that
    /// commits dispatch. No await or authority cached by a prior UI action enters
    /// this transaction. Other connections must serialize or fail the write.
    func dispatchToolCallWithPolicy(id: String, expectedAttempt: Int, descriptor: ToolDescriptor,
                                   safetyCap: ToolPolicySafetyCap, checkedIntentBinding: String,
                                   at now: Date) throws -> ToolCallRecord {
        try changeToolCallAuthorization(id: id, expectedAttempt: expectedAttempt, descriptor: descriptor,
            safetyCap: safetyCap, checkedIntentBinding: checkedIntentBinding, operation: .dispatch, at: now)
    }

    private func changeToolCallAuthorization(id: String, expectedAttempt: Int, descriptor: ToolDescriptor,
        safetyCap: ToolPolicySafetyCap, checkedIntentBinding: String,
        operation: ToolAuthorizationOperation, at now: Date) throws -> ToolCallRecord {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: id) else {
                throw PersistenceError.toolCallNotFound(id)
            }
            guard call.attempt == expectedAttempt, operation.accepts(call.state) else {
                throw PersistenceError.invalidTransition("Tool authorization requires the original pending attempt")
            }
            return try Self.authorizeToolCall(db, call: call, descriptor: descriptor, safetyCap: safetyCap,
                checkedIntentBinding: checkedIntentBinding, operation: operation, at: now)
        }
    }

    private static func authorizeToolCall(_ db: Database, call: ToolCallRecord, descriptor: ToolDescriptor,
        safetyCap: ToolPolicySafetyCap, checkedIntentBinding: String?,
        operation: ToolAuthorizationOperation, at now: Date) throws -> ToolCallRecord {
        if try AgentRunRecord.fetchOne(db, key: call.agentRunID)?.state == .stopping {
            return try updateAuthorizationCall(db, call: call, state: .notExecuted, failure: nil, at: now)
        }
        let facts: ToolAuthorizationFacts
        do {
            facts = try toolAuthorizationFacts(db, call: call, descriptor: descriptor,
                safetyCap: safetyCap, isCreation: operation.isCreation)
        } catch {
            // A corrupt stored authority is unavailable, never a default allow.
            return try rejectAuthorizationCall(db, call: call, failure: .policyDenied, at: now)
        }
        guard checkedIntentBinding.map({ ToolPolicyIdentity.equals($0, facts.binding) }) == true else {
            return try rejectAuthorizationCall(db, call: call, failure: .dependencyChanged, at: now)
        }
        if case .approval(let displayedBinding) = operation,
           let displayedBinding, !ToolPolicyIdentity.equals(displayedBinding, facts.binding) {
            return try rejectAuthorizationCall(db, call: call, failure: .dependencyChanged, at: now)
        }
        var decision = ToolPolicyEvaluator.evaluate(facts.input)
        if facts.isNew {
            let disposition: ToolPolicyAdmissionDisposition
            if operation.isCreation {
                switch decision {
                case .allow: disposition = .allowed
                case .needsApproval: disposition = .needsApproval
                case .deny, .dependencyChanged: disposition = .denied
                }
            } else { disposition = .needsApproval }
            try ToolCallPolicyRecord(toolCallID: call.id, policy: facts.input.currentPolicy,
                disposition: disposition, intentBinding: facts.binding).insert(db)
        }
        if case .approval(let displayedBinding) = operation {
            // Old rows have no prior admission binding. Only a witness carried
            // from the displayed card can approve that first legacy decision.
            if facts.isNew && displayedBinding == nil {
                return try awaitAuthorizationCall(db, call: call, intent: facts.intent, isCreation: false, at: now)
            }
            switch decision {
            case .deny, .dependencyChanged: break
            case .allow, .needsApproval:
                guard facts.intent.approvalDisclosure?.isComplete == true else {
                    return try rejectAuthorizationCall(db, call: call, failure: .reapprovalNeeded, at: now)
                }
                let context = facts.input.call
                let witness = ToolGrantApprovalBinding(toolCallID: call.id, agentRunID: call.agentRunID,
                    intentBinding: facts.binding)
                let grant = ToolScopedGrant(kind: .once(toolCallID: call.id, agentRunID: call.agentRunID,
                        intentBinding: facts.binding), subject: context.subject,
                    toolID: context.toolID, actionID: context.actionID, descriptorRevision: context.descriptorRevision,
                    resource: context.resource, destination: context.destination, validity: .active,
                    revocationEpoch: facts.input.currentPolicy.revocationEpoch, issuedFor: witness)
                guard try issueToolGrant(in: db, id: UUID().uuidString, grant: grant,
                                         expectedPolicy: facts.input.currentPolicy) else {
                    return try rejectAuthorizationCall(db, call: call, failure: .policyDenied, at: now)
                }
                // Reuse the same kernel after issuance; an approval is not a
                // second rule that can override a cap or descriptor restriction.
                let refreshed = try toolAuthorizationFacts(db, call: call, descriptor: descriptor,
                    safetyCap: safetyCap, isCreation: false)
                decision = ToolPolicyEvaluator.evaluate(refreshed.input)
            }
        }
        switch decision {
        case .allow:
            let next: ToolCallState
            switch operation {
            case .creation: next = .prepared
            case .approval: next = .approved
            case .dispatch: next = .dispatched
            case .reconcile: return call
            }
            return try updateAuthorizationCall(db, call: call, state: next, failure: nil, at: now)
        case .needsApproval:
            return try awaitAuthorizationCall(db, call: call, intent: facts.intent,
                isCreation: operation.isCreation, at: now)
        case .deny:
            return try rejectAuthorizationCall(db, call: call, failure: .policyDenied, at: now)
        case .dependencyChanged(let reason):
            let failure: ToolCallFailureReason
            switch reason {
            case .resourceChanged, .destinationChanged, .intentChanged:
                failure = .dependencyChanged
            default: failure = .reapprovalNeeded
            }
            return try rejectAuthorizationCall(db, call: call, failure: failure, at: now)
        }
    }

    private static func toolAuthorizationFacts(_ db: Database, call: ToolCallRecord,
        descriptor: ToolDescriptor, safetyCap: ToolPolicySafetyCap, isCreation: Bool) throws -> ToolAuthorizationFacts {
        guard let json = call.executionIntent else { throw ToolIntentFailure.malformedIntent }
        let intent = try ToolIntentCodec.decodeForDisplay(json)
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard ToolPolicyIdentity.equals(call.action, intent.toolID), let action = intent.policyAction,
              let resource = intent.resourceScope, let destination = intent.destinationScope else {
            throw ToolIntentFailure.invalidScope
        }
        let currentPolicy = try readToolPolicy(db, toolID: action.toolID, actionID: action.actionID,
            descriptorRevision: action.descriptorRevision)
        let stored = try ToolCallPolicyRecord.fetchOne(db, key: call.id)
        let binding = ToolIntentBinding.make(json)
        let record = try stored ?? ToolCallPolicyRecord(toolCallID: call.id, policy: currentPolicy,
            disposition: isCreation ? .allowed : .needsApproval, intentBinding: binding)
        let original = try record.snapshot()
        let run = try AgentRunRecord.fetchOne(db, key: call.agentRunID)
        let conversation = try run.flatMap { try ConversationRecord.fetchOne(db, key: $0.conversationID) }
        let parent = run?.kind == .parent && run?.parentRunID == nil
        let subject = ToolGrantSubject.parentConversation(run?.conversationID ?? "")
        let available = run?.state.isActive == true && run?.state != .stopping
        let context = ToolPolicyCallContext(toolCallID: call.id, agentRunID: call.agentRunID, subject: subject,
            toolID: action.toolID, actionID: action.actionID, descriptorRevision: action.descriptorRevision,
            intentBinding: original.admission.intentBinding, resource: resource, destination: destination,
            authorizationIsAvailable: available, subjectIsAvailable: parent && conversation?.lifecycle == .visible)
        // An old row cannot inherit a different call's grant while its first
        // admission is being recovered. Its explicit approval creates a witness.
        let grants: [ToolScopedGrant]
        if stored != nil || isCreation, let conversationID = run?.conversationID {
            grants = try ToolGrantRecord.filter(Column("subjectKind") == "parentConversation")
                .filter(Column("subjectID") == conversationID).fetchAll(db).map { try $0.snapshot() }
        } else { grants = [] }
        let cap: ToolPolicySafetyCap = safetyCap == .unrestricted && descriptor.approvalRequirement == .required
            ? .requiresExplicitApproval : safetyCap
        return ToolAuthorizationFacts(intent: intent, binding: binding, isNew: stored == nil,
            input: ToolPolicyEvaluationInput(action: action, safetyCap: cap,
                policyAtCreation: original.policy, admission: original.admission, currentPolicy: currentPolicy,
                call: context, resolvedResource: resource, resolvedDestination: destination,
                resolvedIntentBinding: binding, grants: grants))
    }

    private static func awaitAuthorizationCall(_ db: Database, call: ToolCallRecord,
        intent: ToolExecutionIntent, isCreation: Bool, at now: Date) throws -> ToolCallRecord {
        guard intent.approvalDisclosure?.isComplete == true else {
            return try rejectAuthorizationCall(db, call: call, failure: .reapprovalNeeded, at: now)
        }
        let failure: ToolCallFailureReason? = isCreation || call.state == .waitingForApproval
            ? call.failureReason : .reapprovalNeeded
        return try updateAuthorizationCall(db, call: call, state: .waitingForApproval, failure: failure, at: now)
    }

    private static func rejectAuthorizationCall(_ db: Database, call: ToolCallRecord,
        failure: ToolCallFailureReason, at now: Date) throws -> ToolCallRecord {
        let rejected = try updateAuthorizationCall(db, call: call, state: .rejected, failure: failure, at: now)
        try ToolResultRecord(toolCallID: call.id,
            payload: "Tool authorization rejected: \(failure.rawValue).", createdAt: now).insert(db)
        return rejected
    }

    private static func updateAuthorizationCall(_ db: Database, call: ToolCallRecord,
        state: ToolCallState, failure: ToolCallFailureReason?, at now: Date) throws -> ToolCallRecord {
        try db.execute(sql: """
            UPDATE toolCall SET state = ?, failureReason = ?, updatedAt = ?
            WHERE id = ? AND attempt = ? AND state = ?
            """, arguments: [state.rawValue, failure?.rawValue, now, call.id, call.attempt, call.state.rawValue])
        guard db.changesCount == 1 else {
            throw PersistenceError.invalidTransition("Tool authorization lost the original attempt")
        }
        var updated = call
        updated.state = state; updated.failureReason = failure; updated.updatedAt = now
        return updated
    }
}

private enum ToolAuthorizationOperation: Sendable {
    case creation, reconcile, approval(String?), dispatch
    var isCreation: Bool { if case .creation = self { true } else { false } }
    func accepts(_ state: ToolCallState) -> Bool {
        switch self {
        case .creation: state == .validated
        case .approval: state == .waitingForApproval
        case .dispatch: state == .prepared
        case .reconcile: [.validated, .waitingForApproval, .approved, .prepared].contains(state)
        }
    }
}

private struct ToolAuthorizationFacts {
    let intent: ToolExecutionIntent
    let binding: String
    let isNew: Bool
    let input: ToolPolicyEvaluationInput
}
