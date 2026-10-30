import Foundation
import GRDB

struct DelegationRuntimeConfiguration: Sendable, Equatable {
    let enabled: Bool
    let revision: Int64
}

extension PersistenceStore {
    func delegationConfiguration() throws -> DelegationRuntimeConfiguration {
        try database.read { db -> DelegationRuntimeConfiguration in
            try Self.delegationConfiguration(db: db)
        }
    }

    @discardableResult
    func setDelegationEnabled(_ enabled: Bool, at now: Date = Date()) throws -> DelegationRuntimeConfiguration {
        try database.write { db -> DelegationRuntimeConfiguration in
            let current = try Self.delegationConfiguration(db: db)
            guard current.enabled != enabled else { return current }
            let revision = current.revision + 1
            try db.execute(sql: """
                INSERT INTO agentDelegationSettings(id, enabled, revision, updatedAt)
                VALUES ('global', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    enabled = excluded.enabled,
                    revision = excluded.revision,
                    updatedAt = excluded.updatedAt
                """, arguments: [enabled, revision, now])
            return DelegationRuntimeConfiguration(enabled: enabled, revision: revision)
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
                  delegation.maxConcurrentChildren == 1,
                  delegation.modelPolicy == .followParent,
                  delegation.environmentInheritance == .none
            else {
                throw PersistenceError.invalidTransition("Parent snapshot does not permit this Child")
            }
            guard childRun.kind == .child,
                  childRun.parentRunID == parent.id,
                  childRun.conversationID == parent.conversationID,
                  childRun.state == .preparing,
                  childRun.activeSlot == nil,
                  let encodedChildSnapshot = childRun.executionSnapshot,
                  childRun.requestConfigSeed == parent.requestConfigSeed
            else {
                throw PersistenceError.invalidTransition("delegated Child does not match its Parent snapshot")
            }
            let childSnapshot = try ExecutionSnapshotCodec.decode(encodedChildSnapshot)
            guard childSnapshot.formatVersion == RunExecutionSnapshot.currentFormatVersion,
                  childSnapshot.providerID == parentSnapshot.providerID,
                  childSnapshot.providerAdapterRevision == parentSnapshot.providerAdapterRevision,
                  childSnapshot.exposedTools.isEmpty,
                  !childSnapshot.modelCapabilities.contains(.tools),
                  childSnapshot.prompt.memoryReferences.isEmpty,
                  childSnapshot.prompt.skillReferences.isEmpty,
                  childSnapshot.mcpServerDependencies.isEmpty,
                  childSnapshot.delegation == nil
            else {
                throw PersistenceError.invalidTransition("Child snapshot exceeds the first-slice delegation policy")
            }
            guard try AgentRunRecord.fetchOne(db, sql: """
                SELECT * FROM agentRun
                WHERE kind = 'child' AND parentRunID = ?
                  AND state NOT IN ('completed', 'failed', 'cancelled')
                LIMIT 1
                """, arguments: [parent.id]) == nil else {
                throw PersistenceError.invalidTransition("Parent already has an active Child")
            }
            guard try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM delegatedChildRun WHERE parentToolCallID = ? OR childRunID = ?",
                arguments: [parentToolCallID, childRun.id]
            ) == nil else {
                throw PersistenceError.invalidTransition("delegation call already owns a Child Run")
            }

            try childRun.insert(db)
            try db.execute(sql: """
                INSERT INTO delegatedChildRun(parentToolCallID, childRunID, createdAt)
                VALUES (?, ?, ?)
                """, arguments: [parentToolCallID, childRun.id, now])
        }
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
        guard expectedParentState == .recovering || expectedParentState == .stopping else {
            throw PersistenceError.invalidTransition("delegated outcome requires Parent recovery or stop")
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
        guard expectedParentState == .recovering || expectedParentState == .stopping else {
            throw PersistenceError.invalidTransition("delegated outcome confirmation requires Parent recovery or stop")
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
                ORDER BY child.createdAt, child.id
                """, arguments: [parentRunID, parentRunID])
            var settled: [String] = []
            for child in children {
                if terminalState == .cancelled, child.state != .stopping {
                    guard RunStateMachine.canTransition(from: child.state, to: .stopping) else {
                        throw PersistenceError.invalidTransition("active Child cannot enter stopping")
                    }
                    try db.execute(sql: """
                        UPDATE agentRun
                        SET state = 'stopping', endReason = NULL, recoveryAction = NULL,
                            suspendReason = NULL, updatedAt = ?
                        WHERE id = ? AND state = ?
                        """, arguments: [now, child.id, child.state.rawValue])
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
            sql: "SELECT enabled, revision FROM agentDelegationSettings WHERE id = 'global'"
        ) else {
            return DelegationRuntimeConfiguration(enabled: false, revision: 0)
        }
        let enabled: Bool = row["enabled"]
        let revision: Int64 = row["revision"]
        return DelegationRuntimeConfiguration(enabled: enabled, revision: revision)
    }
}

private struct DelegatedChildTerminalReport: Encodable {
    let childRunID: String
    let state: String
    let endReason: String?
}
