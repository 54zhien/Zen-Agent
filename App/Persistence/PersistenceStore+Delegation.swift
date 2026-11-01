import Foundation
import GRDB

struct DelegationModelTarget: Codable, Sendable, Equatable {
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

struct DelegationRuntimeConfiguration: Sendable, Equatable {
    let enabled: Bool
    let explicitModelTarget: DelegationModelTarget?
    let revision: Int64
}

extension PersistenceStore {
    func delegationConfiguration() throws -> DelegationRuntimeConfiguration {
        try database.read { db -> DelegationRuntimeConfiguration in
            try Self.delegationConfiguration(db: db)
        }
    }

    @discardableResult
    func setDelegationConfiguration(
        enabled: Bool,
        explicitModelTarget: DelegationModelTarget?,
        at now: Date = Date()
    ) throws -> DelegationRuntimeConfiguration {
        try database.write { db in
            try Self.persistDelegationConfiguration(
                enabled: enabled,
                explicitModelTarget: explicitModelTarget,
                in: db,
                at: now
            )
        }
    }

    @discardableResult
    func setDelegationEnabled(_ enabled: Bool, at now: Date = Date()) throws -> DelegationRuntimeConfiguration {
        try database.write { db -> DelegationRuntimeConfiguration in
            let current = try Self.delegationConfiguration(db: db)
            return try Self.persistDelegationConfiguration(
                enabled: enabled,
                explicitModelTarget: current.explicitModelTarget,
                in: db,
                at: now
            )
        }
    }

    func createDelegatedChildRun(parentToolCallID: String, childRun: AgentRunRecord, at now: Date = Date()) throws {
        try database.write { db in
            guard let call = try ToolCallRecord.fetchOne(db, key: parentToolCallID),
                  call.action == SubagentDelegationTool.toolID,
                  call.state == .dispatched || call.state == .indeterminate,
                  let parent = try AgentRunRecord.fetchOne(db, key: call.agentRunID),
                  parent.kind == .parent,
                  parent.parentRunID == nil,
                  let encodedSnapshot = parent.executionSnapshot
            else {
                throw PersistenceError.invalidTransition("delegation requires an enabled Parent tool call")
            }
            let parentMayCreateChild: Bool
            switch parent.state {
            case .executingTools:
                parentMayCreateChild = call.state == .dispatched
            case .recovering:
                parentMayCreateChild = parent.recoveryAction == .resume
                    && (call.state == .dispatched || call.state == .indeterminate)
            default:
                parentMayCreateChild = false
            }
            guard parentMayCreateChild else {
                throw PersistenceError.invalidTransition("Parent state does not permit Child creation")
            }
            let parentSnapshot = try ExecutionSnapshotCodec.decode(encodedSnapshot)
            guard let delegation = parentSnapshot.delegation,
                  delegation.enabled,
                  delegation.maxDepth == 1,
                  delegation.supportsFrozenConcurrencyLimit,
                  delegation.environmentInheritance == .none,
                  parentSnapshot.permitsTool(SubagentDelegationTool.toolDescriptor)
            else {
                throw PersistenceError.invalidTransition("Parent snapshot does not permit this Child")
            }
            guard childRun.kind == .child,
                  childRun.parentRunID == parent.id,
                  childRun.conversationID == parent.conversationID,
                  childRun.state == .preparing,
                  childRun.activeSlot == nil,
                  let encodedChildSnapshot = childRun.executionSnapshot
            else {
                throw PersistenceError.invalidTransition("delegated Child does not match its Parent snapshot")
            }
            let childSnapshot = try ExecutionSnapshotCodec.decode(encodedChildSnapshot)
            let expectedModelCapabilities: Set<ModelCapability>
            switch delegation.modelPolicy {
            case .followParent:
                guard delegation.explicitModelTarget == nil,
                      delegation.explicitModelBinding == nil,
                      childRun.requestConfigSeed == parent.requestConfigSeed,
                      childSnapshot.providerID == parentSnapshot.providerID,
                      childSnapshot.providerAdapterRevision == parentSnapshot.providerAdapterRevision
                else {
                    throw PersistenceError.invalidTransition("Follow Parent Child must use the frozen Parent model")
                }
                expectedModelCapabilities = parentSnapshot.modelCapabilities
            case .explicit:
                guard let target = delegation.explicitModelTarget,
                      let binding = delegation.explicitModelBinding,
                      target.providerInstanceID == binding.requestConfigSeed.providerInstanceID,
                      target.modelID == binding.requestConfigSeed.modelID,
                      childRun.requestConfigSeed == binding.requestConfigSeed,
                      childSnapshot.providerID == binding.providerID,
                      childSnapshot.providerAdapterRevision == binding.providerAdapterRevision
                else {
                    throw PersistenceError.invalidTransition("Explicit Child must use its frozen model binding")
                }
                expectedModelCapabilities = binding.modelCapabilities
            }
            let childModelCapabilitiesMatch = childSnapshot.modelCapabilities == expectedModelCapabilities
                || (childSnapshot.exposedTools.isEmpty
                    && childSnapshot.modelCapabilities == expectedModelCapabilities.subtracting([.tools]))
            let requestedEnvironmentKeys = try Self.requestedDelegationEnvironmentKeys(
                call: call,
                parent: parent,
                parentSnapshot: parentSnapshot,
                db: db
            )
            let childMemoryReferences = childSnapshot.prompt.memoryReferences
            let childSkillReferences = childSnapshot.prompt.skillReferences
            guard childMemoryReferences.allSatisfy({ parentSnapshot.prompt.memoryReferences.contains($0) }),
                  childSkillReferences.allSatisfy({ parentSnapshot.prompt.skillReferences.contains($0) })
            else {
                throw PersistenceError.invalidTransition("Child context must use exact frozen Parent references")
            }
            _ = try Self.resolveMemoryReferences(childMemoryReferences, db: db)
            let childSkillItems = try Self.resolveSkillItems(childSkillReferences, db: db)
            guard childSkillItems.allSatisfy({ item in
                item.definition.requiredMCPServers.isEmpty
                    && Set(item.definition.environmentKeys).isSubset(of: requestedEnvironmentKeys)
            }) else {
                throw PersistenceError.invalidTransition("Child Skills exceed its explicit Parent Environment selection")
            }
            let childToolsStayWithinParent = childSnapshot.exposedTools.allSatisfy { childTool in
                !ToolPolicyIdentity.equals(childTool.toolID, SubagentDelegationTool.toolID)
                    && MCPToolExecutable.serverID(forToolID: childTool.toolID) == nil
                    && parentSnapshot.exposedTools.contains { parentTool in
                        ToolPolicyIdentity.equals(parentTool.toolID, childTool.toolID)
                            && ToolPolicyIdentity.equals(parentTool.descriptorRevision, childTool.descriptorRevision)
                    }
            }
            guard childSnapshot.formatVersion == RunExecutionSnapshot.currentFormatVersion,
                  childModelCapabilitiesMatch,
                  childToolsStayWithinParent,
                  childSnapshot.exposedTools.isEmpty || childSnapshot.modelCapabilities.contains(.tools),
                  childSnapshot.mcpServerDependencies.isEmpty,
                  childSnapshot.delegation == nil
            else {
                throw PersistenceError.invalidTransition("Child snapshot exceeds its Parent's frozen delegation policy")
            }
            let activeChildCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM agentRun
                WHERE kind = 'child' AND parentRunID = ?
                  AND state NOT IN ('completed', 'failed', 'cancelled')
                """, arguments: [parent.id]) ?? 0
            guard activeChildCount < delegation.maxConcurrentChildren else {
                throw PersistenceError.invalidTransition("Parent reached its frozen active Child limit")
            }
            guard try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM delegatedChildRun WHERE parentToolCallID = ? OR childRunID = ?",
                arguments: [parentToolCallID, childRun.id]
            ) == nil else {
                throw PersistenceError.invalidTransition("delegation call already owns a Child Run")
            }

            try childRun.insert(db)
            let skillSelection = String(decoding: try JSONEncoder().encode(childSkillReferences), as: UTF8.self)
            try db.execute(sql: "INSERT INTO runSkillSelection(runID, selectionJSON) VALUES (?, ?)",
                arguments: [childRun.id, skillSelection])
            try Self.validateExtensionDependencies(runID: childRun.id, snapshot: childSnapshot, db: db)
            try db.execute(sql: """
                INSERT INTO delegatedChildRun(parentToolCallID, childRunID, createdAt)
                VALUES (?, ?, ?)
                """, arguments: [parentToolCallID, childRun.id, now])
        }
    }

    private static func requestedDelegationEnvironmentKeys(
        call: ToolCallRecord,
        parent: AgentRunRecord,
        parentSnapshot: RunExecutionSnapshot,
        db: Database
    ) throws -> Set<String> {
        guard let encodedIntent = call.executionIntent else {
            throw PersistenceError.invalidTransition("delegation has no frozen ToolCall intent")
        }
        let intent = try ToolIntentCodec.decodeForDisplay(encodedIntent)
        try ToolIntentCodec.validate(intent, descriptor: SubagentDelegationTool.toolDescriptor)
        guard intent.resourceScope == .target(parent.id),
              intent.destinationScope == ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed).destination,
              let action = intent.policyAction,
              action.actionID == SubagentDelegationTool.actionID
        else {
            throw PersistenceError.invalidTransition("delegation intent does not belong to its Parent Run")
        }

        let arguments = try ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON)
        let requested: [String]
        if let rawKeys = arguments["environmentKeys"] {
            guard let keys = rawKeys as? [String] else {
                throw PersistenceError.invalidTransition("delegation Environment selection is not a key list")
            }
            requested = keys
        } else {
            requested = []
        }
        guard Set(requested).count == requested.count,
              requested.allSatisfy(EnvironmentValidation.allowsKey)
        else {
            throw PersistenceError.invalidTransition("delegation Environment selection has duplicate or invalid keys")
        }

        let frozenReferences = Array(Set(parentSnapshot.prompt.skillReferences.flatMap(\.environmentReferences))).sorted {
            if $0.variableID != $1.variableID { return $0.variableID < $1.variableID }
            return $0.revisionID < $1.revisionID
        }
        let frozenKeys = Set(try Self.resolveEnvironmentReferences(frozenReferences, db: db).map(\.key))
        let requestedKeys = Set(requested)
        guard requestedKeys.isSubset(of: frozenKeys) else {
            throw PersistenceError.invalidTransition("delegation requested an Environment key outside the Parent snapshot")
        }
        return requestedKeys
    }

    func delegatedChildRunID(parentToolCallID: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: """
                SELECT childRunID FROM delegatedChildRun WHERE parentToolCallID = ?
                """, arguments: [parentToolCallID])
        }
    }

    func activeDelegatedChildRunIDs(parentRunID: String) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT r.id FROM delegatedChildRun d
                JOIN agentRun r ON r.id = d.childRunID
                WHERE r.parentRunID = ?
                  AND r.state NOT IN ('completed', 'failed', 'cancelled')
                ORDER BY d.createdAt, d.childRunID
                """, arguments: [parentRunID])
        }
    }

    func delegatedChildOutcome(runID: String) throws -> ToolExecutionResult? {
        try database.read { db in
            guard let child = try AgentRunRecord.fetchOne(db, key: runID),
                  child.kind == .child,
                  let parentRunID = child.parentRunID,
                  try Row.fetchOne(db, sql: """
                    SELECT 1 FROM delegatedChildRun d
                    JOIN toolCall c ON c.id = d.parentToolCallID
                    JOIN agentRun p ON p.id = c.agentRunID
                    WHERE d.childRunID = ? AND p.id = ?
                      AND p.kind = 'parent' AND p.parentRunID IS NULL
                    """, arguments: [runID, parentRunID]) != nil
            else { return nil }
            return try Self.terminalChildOutcome(child, db: db)
        }
    }

    func delegatedToolOutcome(
        parentToolCallID: String,
        attempt: Int,
        intentBinding: String,
        expectedParentState: RunState
    ) throws -> ToolExecutionResult? {
        guard expectedParentState == .executingTools
                || expectedParentState == .recovering
                || expectedParentState == .stopping else {
            throw PersistenceError.invalidTransition("delegated outcome requires Parent tool execution, recovery, or stop")
        }
        return try database.read { db -> ToolExecutionResult? in
            guard let call = try ToolCallRecord.fetchOne(db, key: parentToolCallID),
                  call.action == SubagentDelegationTool.toolID,
                  call.attempt == attempt,
                  call.state == .dispatched || call.state == .indeterminate,
                  let encodedIntent = call.executionIntent,
                  ToolPolicyIdentity.equals(ToolIntentBinding.make(encodedIntent), intentBinding),
                  let parent = try AgentRunRecord.fetchOne(db, key: call.agentRunID),
                  parent.kind == .parent,
                  parent.parentRunID == nil,
                  parent.state == expectedParentState,
                  expectedParentState != .recovering
                    || parent.recoveryAction == .resume
                    || parent.recoveryAction == .invalidate,
                  let childID = try String.fetchOne(db, sql: """
                    SELECT childRunID FROM delegatedChildRun WHERE parentToolCallID = ?
                    """, arguments: [parentToolCallID]),
                  let child = try AgentRunRecord.fetchOne(db, key: childID),
                  child.kind == .child, child.parentRunID == parent.id,
                  let outcome = try Self.terminalChildOutcome(child, db: db)
            else { return nil }
            return outcome
        }
    }

    func confirmDelegatedToolOutcome(
        parentToolCallID: String,
        attempt: Int,
        intentBinding: String,
        expectedParentState: RunState,
        observedOutcome: ToolExecutionResult,
        result: ToolExecutionResult,
        at now: Date = Date()
    ) throws -> Bool {
        guard expectedParentState == .executingTools
                || expectedParentState == .recovering
                || expectedParentState == .stopping else {
            throw PersistenceError.invalidTransition("delegated outcome confirmation requires Parent tool execution, recovery, or stop")
        }
        return try database.write { db -> Bool in
            guard let call = try ToolCallRecord.fetchOne(db, key: parentToolCallID),
                  call.action == SubagentDelegationTool.toolID,
                  call.attempt == attempt,
                  call.state == .dispatched || call.state == .indeterminate,
                  let encodedIntent = call.executionIntent,
                  ToolPolicyIdentity.equals(ToolIntentBinding.make(encodedIntent), intentBinding),
                  let parent = try AgentRunRecord.fetchOne(db, key: call.agentRunID),
                  parent.kind == .parent,
                  parent.parentRunID == nil,
                  parent.state == expectedParentState,
                  expectedParentState != .recovering
                    || parent.recoveryAction == .resume
                    || parent.recoveryAction == .invalidate,
                  let childID = try String.fetchOne(db, sql: """
                    SELECT childRunID FROM delegatedChildRun WHERE parentToolCallID = ?
                    """, arguments: [parentToolCallID]),
                  let child = try AgentRunRecord.fetchOne(db, key: childID),
                  child.kind == .child, child.parentRunID == parent.id,
                  let currentOutcome = try Self.terminalChildOutcome(child, db: db),
                  currentOutcome.content.utf8.elementsEqual(observedOutcome.content.utf8),
                  currentOutcome.kind == observedOutcome.kind,
                  currentOutcome.failure == observedOutcome.failure
            else { return false }

            let terminalState: ToolCallState = result.failure == nil ? .succeeded : .failed
            try db.execute(sql: """
                UPDATE toolCall SET state = ?, failureReason = NULL, updatedAt = ?
                WHERE id = ? AND attempt = ? AND state IN ('dispatched', 'indeterminate')
                """, arguments: [terminalState.rawValue, now, parentToolCallID, attempt])
            guard db.changesCount == 1 else { return false }
            try ToolResultRecord(toolCallID: parentToolCallID, payload: result.content, createdAt: now,
                kind: result.kind, failureCode: result.failure).insert(db)
            return true
        }
    }

    func cancelTasklessDelegatedChildren(parentRunID: String, at now: Date = Date()) throws -> [String] {
        try settleTasklessDelegatedChildren(
            parentRunID: parentRunID,
            parentState: .stopping,
            terminalState: .cancelled,
            endReason: .cancelledByUser,
            openPartState: .cancelled,
            at: now
        )
    }

    func cancelTasklessDelegatedChild(
        parentRunID: String,
        childRunID: String,
        at now: Date = Date()
    ) throws -> [String] {
        try settleTasklessDelegatedChildren(
            parentRunID: parentRunID,
            parentState: .stopping,
            terminalState: .cancelled,
            endReason: .cancelledByUser,
            openPartState: .cancelled,
            childRunID: childRunID,
            at: now
        )
    }

    func failUnknownDelegatedChildren(
        parentRunID: String,
        endReason: EndReason,
        at now: Date = Date()
    ) throws -> [String] {
        try settleTasklessDelegatedChildren(
            parentRunID: parentRunID,
            parentState: .recovering,
            recoveryAction: .resume,
            terminalState: .failed,
            endReason: endReason,
            openPartState: .failed,
            at: now
        )
    }

    func failDelegatedChildrenAfterParentInvalidation(
        parentRunID: String,
        at now: Date = Date()
    ) throws -> [String] {
        try settleTasklessDelegatedChildren(
            parentRunID: parentRunID,
            parentState: .recovering,
            recoveryAction: .invalidate,
            terminalState: .failed,
            endReason: .dependencyUnavailable,
            openPartState: .failed,
            at: now
        )
    }

    func settleUndispatchedDelegatedToolCalls(
        parentRunID: String,
        expectedParentState: RunState,
        at now: Date = Date()
    ) throws -> [String] {
        let result = ToolExecutionResult(
            content: "Delegation ended before a Child Run was created.",
            kind: .error,
            failure: .executionFailed
        )

        return try database.write { db in
            guard let parent = try AgentRunRecord.fetchOne(db, key: parentRunID),
                  parent.kind == .parent,
                  parent.parentRunID == nil,
                  parent.state == expectedParentState,
                  expectedParentState == .stopping
                    || (expectedParentState == .recovering && parent.recoveryAction == .invalidate)
            else {
                throw PersistenceError.invalidTransition("delegation settlement requires a stopping or invalidated Parent")
            }

            let calls = try ToolCallRecord.fetchAll(db, sql: """
                SELECT c.* FROM toolCall c
                WHERE c.agentRunID = ? AND c.action = ?
                  AND c.state IN (?, ?, ?, ?, ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM delegatedChildRun d WHERE d.parentToolCallID = c.id
                  )
                ORDER BY c.createdAt, c.id
                """, arguments: [
                    parentRunID,
                    SubagentDelegationTool.toolID,
                    ToolCallState.validated.rawValue,
                    ToolCallState.waitingForApproval.rawValue,
                    ToolCallState.waitingForSystemPermissionConsent.rawValue,
                    ToolCallState.approved.rawValue,
                    ToolCallState.prepared.rawValue,
                ])
            var settled: [String] = []
            for call in calls {
                try db.execute(sql: """
                    UPDATE toolCall SET state = ?, failureReason = NULL, updatedAt = ?
                    WHERE id = ? AND state = ?
                    """, arguments: [
                        ToolCallState.notExecuted.rawValue,
                        now,
                        call.id,
                        call.state.rawValue,
                    ])
                guard db.changesCount == 1 else {
                    throw PersistenceError.invalidTransition("undispatched delegation changed during Parent settlement")
                }
                try ToolResultRecord(
                    toolCallID: call.id,
                    payload: result.content,
                    createdAt: now,
                    kind: result.kind,
                    failureCode: result.failure
                ).insert(db)
                settled.append(call.id)
            }
            return settled
        }
    }

    private func settleTasklessDelegatedChildren(
        parentRunID: String,
        parentState: RunState,
        recoveryAction: RecoveryAction? = nil,
        terminalState: RunState,
        endReason: EndReason,
        openPartState: MessagePartState,
        childRunID: String? = nil,
        at now: Date
    ) throws -> [String] {
        try database.write { db in
            guard let parent = try AgentRunRecord.fetchOne(db, key: parentRunID),
                  parent.kind == .parent,
                  parent.parentRunID == nil,
                  parent.state == parentState,
                  (parentState != .recovering || parent.recoveryAction == recoveryAction)
            else {
                throw PersistenceError.invalidTransition("taskless Child settlement requires an eligible Parent")
            }
            let children = try AgentRunRecord.fetchAll(db, sql: """
                SELECT child.* FROM agentRun child
                JOIN delegatedChildRun d ON d.childRunID = child.id
                JOIN toolCall delegationCall ON delegationCall.id = d.parentToolCallID
                WHERE delegationCall.agentRunID = ? AND child.parentRunID = ?
                  AND child.kind = 'child'
                  AND child.state NOT IN ('completed', 'failed', 'cancelled')
                  AND (? IS NULL OR child.id = ?)
                ORDER BY child.createdAt, child.id
                """, arguments: [parentRunID, parentRunID, childRunID, childRunID])
            var settled: [String] = []
            for child in children {
                if terminalState == .cancelled, child.state != .stopping {
                    guard RunStateMachine.canTransition(from: child.state, to: .stopping) else {
                        throw PersistenceError.invalidTransition("active Child cannot enter stopping")
                    }
                    try db.execute(sql: """
                        UPDATE agentRun
                        SET state = 'stopping', endReason = NULL, recoveryAction = NULL,
                            suspendReason = NULL,
                            stopRequestedAt = COALESCE(stopRequestedAt, ?), updatedAt = ?
                        WHERE id = ? AND state = ?
                        """, arguments: [now, now, child.id, child.state.rawValue])
                    guard db.changesCount == 1 else {
                        throw PersistenceError.invalidTransition("Child state changed during taskless settlement")
                    }
                } else {
                    guard RunStateMachine.canTransition(from: child.state, to: terminalState) else {
                        throw PersistenceError.invalidTransition("active Child cannot reach its terminal state")
                    }
                }

                try db.execute(sql: """
                    UPDATE messagePart SET state = ?
                    WHERE messageID = (SELECT responseMessageID FROM agentRun WHERE id = ?)
                      AND state IN (?, ?)
                    """, arguments: [
                        openPartState.rawValue,
                        child.id,
                        MessagePartState.pending.rawValue,
                        MessagePartState.streaming.rawValue,
                    ])
                try db.execute(sql: """
                    UPDATE toolCall
                    SET state = CASE WHEN state = ? THEN ? ELSE ? END,
                        failureReason = CASE WHEN state = ? THEN ? ELSE NULL END,
                        updatedAt = ?
                    WHERE agentRunID = ? AND state IN (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        ToolCallState.dispatched.rawValue,
                        ToolCallState.indeterminate.rawValue,
                        ToolCallState.notExecuted.rawValue,
                        ToolCallState.dispatched.rawValue,
                        ToolCallFailureReason.outcomeUnknown.rawValue,
                        now,
                        child.id,
                        ToolCallState.validated.rawValue,
                        ToolCallState.waitingForApproval.rawValue,
                        ToolCallState.waitingForSystemPermissionConsent.rawValue,
                        ToolCallState.approved.rawValue,
                        ToolCallState.prepared.rawValue,
                        ToolCallState.dispatched.rawValue,
                    ])
                try db.execute(sql: """
                    UPDATE agentRun
                    SET state = ?, endReason = ?, recoveryAction = NULL,
                        suspendReason = NULL, activeSlot = NULL, updatedAt = ?
                    WHERE id = ? AND state = ?
                    """, arguments: [
                        terminalState.rawValue,
                        endReason.rawValue,
                        now,
                        child.id,
                        terminalState == .cancelled ? RunState.stopping.rawValue : child.state.rawValue,
                    ])
                guard db.changesCount == 1 else {
                    throw PersistenceError.invalidTransition("Child state changed before settlement")
                }
                settled.append(child.id)
            }
            return settled
        }
    }

    private static func terminalChildOutcome(_ child: AgentRunRecord, db: Database) throws -> ToolExecutionResult? {
        switch child.state {
        case .completed:
            guard child.endReason == .completed else { return nil }
            if let messageID = child.responseMessageID {
                let parts = try MessagePartRecord.fetchAll(db, sql: """
                    SELECT * FROM messagePart
                    WHERE messageID = ? AND kind = 'text'
                    ORDER BY sequence, id
                    """, arguments: [messageID])
                guard parts.allSatisfy({ $0.state == .completed }) else { return nil }
                let text = try parts.map { try PersistenceStore.decodeTextPayload($0.payload).text }
                    .joined()
                return ToolExecutionResult(content: text)
            }
            return ToolExecutionResult(content: "")
        case .failed, .cancelled:
            let report = DelegatedChildTerminalReport(
                childRunID: child.id,
                state: child.state.rawValue,
                endReason: child.endReason?.rawValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return ToolExecutionResult(
                content: String(decoding: try encoder.encode(report), as: UTF8.self),
                kind: .error,
                failure: .executionFailed
            )
        default:
            return nil
        }
    }

    private static func delegationConfiguration(db: Database) throws -> DelegationRuntimeConfiguration {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT enabled, explicitModelTarget, revision FROM agentDelegationSettings WHERE id = 'global'"
        ) else {
            return DelegationRuntimeConfiguration(enabled: false, explicitModelTarget: nil, revision: 0)
        }
        let enabled: Bool = row["enabled"]
        let encodedTarget: String? = row["explicitModelTarget"]
        let explicitModelTarget = try encodedTarget.map {
            try JSONDecoder().decode(DelegationModelTarget.self, from: Data($0.utf8))
        }
        let revision: Int64 = row["revision"]
        return DelegationRuntimeConfiguration(
            enabled: enabled,
            explicitModelTarget: explicitModelTarget,
            revision: revision
        )
    }

    private static func persistDelegationConfiguration(
        enabled: Bool,
        explicitModelTarget: DelegationModelTarget?,
        in db: Database,
        at now: Date
    ) throws -> DelegationRuntimeConfiguration {
        let current = try delegationConfiguration(db: db)
        guard current.enabled != enabled || current.explicitModelTarget != explicitModelTarget else {
            return current
        }

        let revision = current.revision + 1
        let encodedTarget: String?
        if let explicitModelTarget {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encodedTarget = String(decoding: try encoder.encode(explicitModelTarget), as: UTF8.self)
        } else {
            encodedTarget = nil
        }
        try db.execute(sql: """
            INSERT INTO agentDelegationSettings(id, enabled, explicitModelTarget, revision, updatedAt)
            VALUES ('global', ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                enabled = excluded.enabled,
                explicitModelTarget = excluded.explicitModelTarget,
                revision = excluded.revision,
                updatedAt = excluded.updatedAt
            """, arguments: [enabled, encodedTarget, revision, now])
        return DelegationRuntimeConfiguration(
            enabled: enabled,
            explicitModelTarget: explicitModelTarget,
            revision: revision
        )
    }
}

private struct DelegatedChildTerminalReport: Encodable {
    let childRunID: String
    let state: String
    let endReason: String?
}
