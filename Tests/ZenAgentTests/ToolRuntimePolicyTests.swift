import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("S6-04a Runtime policy authority")
struct ToolRuntimePolicyTests {
    @Test func defaultAskWaitsWithoutEnteringExecutor() async throws {
        let f = try RuntimePolicyFixture()
        let result = try await f.complete()
        #expect(result == nil)
        #expect(try f.call().state == .waitingForApproval)
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.store.toolResult(toolCallID: f.call().id) == nil)
    }

    @Test func denySettlesOriginalCallWithoutDispatch() async throws {
        let f = try RuntimePolicyFixture(policy: .deny)
        let result = try await f.complete()
        #expect(result != nil)
        #expect(try f.call().state == .rejected)
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.store.toolResult(toolCallID: f.call().id) != nil)
        #expect(try f.store.toolCalls(inRun: "r").count == 1)
    }

    @Test func explicitAlwaysAllowStillCommitsBeforeExecutor() async throws {
        let f = try RuntimePolicyFixture(policy: .alwaysAllow)
        #expect(try await f.complete()?.content == "done")
        let call = try f.call()
        let entries = await f.probe.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.callID == call.id)
        #expect(entries.first?.observedState == .dispatched)
        #expect(try f.store.toolCall(id: call.id)?.state == .succeeded)
    }

    @Test func approvalIssuesAndConsumesOneOriginalIntentGrant() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let original = try f.call()
        try f.runtime.approve(toolCallID: original.id)
        let issued = try f.store.toolGrants(subject: .parentConversation("c"))
        let grant = try #require(issued.first?.grant)
        #expect(issued.count == 1)
        #expect(grant.validity == .active)
        #expect(grant.issuedFor?.toolCallID == original.id)
        #expect(grant.issuedFor?.agentRunID == "r")
        if case .once(let callID, let runID, _) = grant.kind {
            #expect(callID == original.id && runID == "r")
        } else { Issue.record("explicit one-call approval must issue a once grant") }
        #expect(try await f.runtime.executeApproved(toolCallID: original.id).content == "done")
        #expect(try f.store.toolGrant(id: issued[0].id)?.validity == .consumed)
        #expect(try f.call().executionIntent == original.executionIntent)
        #expect(try f.store.toolCalls(inRun: "r").count == 1)
    }

    @Test func tightenWhileCardIsOpenBeatsApproval() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.set(.deny)
        try f.runtime.approve(toolCallID: call.id)
        #expect(try f.call().state == .rejected)
        #expect(try f.store.toolResult(toolCallID: call.id) != nil)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
        #expect(await f.probe.entries().isEmpty)
    }

    @Test func tightenAfterApprovalBeatsExecution() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        try f.set(.deny)
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(try f.call().state == .rejected)
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.store.toolResult(toolCallID: call.id) != nil)
    }

    @Test func tighteningInDependencyPreflightIsReadAtDispatch() async throws {
        let f = try RuntimePolicyFixture(policy: .alwaysAllow, dependencyCheck: { store in
            try store.setToolPolicy(toolID: RuntimePolicyTool.id, actionID: "read", descriptorRevision: "r1", mode: .deny)
        })
        _ = try await f.complete()
        #expect(try f.call().state == .rejected)
        #expect(await f.probe.entries().isEmpty)
    }

    @Test func revokedOnceGrantCannotBeReusedAtDispatch() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        let id = try #require(try f.store.toolGrants(subject: .parentConversation("c")).first?.id)
        try #require(try f.store.revokeToolGrant(id: id))
        do { _ = try await f.runtime.executeApproved(toolCallID: call.id) }
        catch { /* A new decision belongs to the existing Runtime waiter. */ }
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .waitingForApproval)
        #expect(try f.store.toolGrant(id: id)?.validity == .revoked)
    }

    @Test func settingsWideningDoesNotActivateOldWaitingAdmission() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        // An old persisted approval is not a current trusted grant. This models
        // recovery of an older writer, not a second user approval operation.
        try f.store.approveToolCall(id: call.id)
        try f.store.markToolCallPrepared(id: call.id)
        try f.set(.alwaysAllow)
        do { _ = try await f.runtime.executePrepared(toolCallID: call.id) }
        catch { }
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .waitingForApproval)
        #expect(try f.call().id == call.id)
    }

    @Test func legacyPreparedWithoutAdmissionNeedsOriginalCallReapproval() async throws {
        let f = try RuntimePolicyFixture(policy: .alwaysAllow)
        let json = String(decoding: try JSONEncoder().encode(f.tool.prepare(callID: "old", argumentsJSON: "{}")), as: UTF8.self)
        try f.store.createToolCall(Fixtures.toolCall(id: "old", runID: "r", action: RuntimePolicyTool.id,
            state: .prepared, intent: json))
        do { _ = try await f.runtime.executePrepared(toolCallID: "old") }
        catch { }
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .waitingForApproval)
        #expect(try f.call().executionIntent == json)
        #expect(try f.store.toolCalls(inRun: "r").count == 1)
        #expect(try f.store.toolResult(toolCallID: "old") == nil)
    }

    @Test func hiddenSubjectCannotUseAnApprovedCall() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        try f.store.database.write { db in
            try db.execute(sql: "UPDATE conversation SET lifecycle = 'pendingDeletion' WHERE id = 'c'")
        }
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .rejected)
    }

    @Test func hardCapCannotBeBypassedByOldApproval() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        let stricter = ToolRuntime(store: f.store, registry: try ToolRegistry(tools: [f.tool]), safetyCap: .deny)
        _ = try await stricter.executeApproved(toolCallID: call.id)
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .rejected)
    }

    @Test func hardCapRejectsEvenWithGlobalAlwaysAllow() async throws {
        let f = try RuntimePolicyFixture(policy: .alwaysAllow, safetyCap: .deny)
        _ = try await f.complete()
        #expect(try f.call().state == .rejected)
        #expect(await f.probe.entries().isEmpty)
    }

    @Test func changedPolicyDescriptorCannotAuthorizeOldIntent() async throws {
        let f = try RuntimePolicyFixture()
        try f.store.setToolPolicy(toolID: RuntimePolicyTool.id, actionID: "read", descriptorRevision: "r2", mode: .alwaysAllow)
        _ = try await f.complete()
        #expect(try f.call().state == .rejected)
        #expect(await f.probe.entries().isEmpty)
    }

    @Test func changedAttemptBeforeCheckpointCannotDispatchOldAttempt() async throws {
        let f = try RuntimePolicyFixture(policy: .alwaysAllow, dependencyCheck: { store in
            try store.database.write { db in
                try db.execute(sql: "UPDATE toolCall SET attempt = 2 WHERE agentRunID = 'r'")
            }
        })
        do { _ = try await f.complete() }
        catch { }
        #expect(await f.probe.entries().isEmpty)
        #expect(try f.call().state == .prepared)
        #expect(try f.call().attempt == 2)
    }

    @Test func approvedGrantSurvivesReopenThenConsumesOnOriginalCall() async throws {
        let url = try Fixtures.scratchPath(name: "runtime-policy-reopen.sqlite")
        defer { Fixtures.cleanUp(url) }
        let callID: String
        do {
            let f = try RuntimePolicyFixture(database: ZenDatabase.open(at: url.path()), requiresApproval: true)
            _ = try await f.complete()
            callID = try f.call().id
            try f.runtime.approve(toolCallID: callID)
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let probe = RuntimePolicyProbe()
        let tool = RuntimePolicyTool(store: store, probe: probe, requiresApproval: true)
        let runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [tool]))
        #expect(try await runtime.executeApproved(toolCallID: callID).content == "done")
        let grants = try store.toolGrants(subject: .parentConversation("c"))
        #expect(grants.count == 1)
        #expect(grants.first?.grant.validity == .consumed)
        #expect(await probe.entries().first?.callID == callID)
        #expect(try store.toolCalls(inRun: "r").count == 1)
    }

    @Test func duplicateDispatchEntersExecutorAtMostOnce() async throws {
        let f = try RuntimePolicyFixture(requiresApproval: true)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        try f.store.markToolCallPrepared(id: call.id)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask { _ = try? await f.runtime.executePrepared(toolCallID: call.id) }
            }
            await group.waitForAll()
        }
        #expect(await f.probe.entries().count == 1)
        #expect(try f.call().state == .succeeded)
    }
}

private struct RuntimePolicyFixture: Sendable {
    let store: PersistenceStore
    let probe: RuntimePolicyProbe
    let tool: RuntimePolicyTool
    let runtime: ToolRuntime

    init(database: ZenDatabase? = nil, policy: ToolPersistentPolicy? = nil,
         requiresApproval: Bool = false, safetyCap: ToolPolicySafetyCap = .unrestricted,
         dependencyCheck: @escaping @Sendable (PersistenceStore) throws -> Void = { _ in }) throws {
        let store = PersistenceStore(database: try database ?? ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        if let policy {
            try store.setToolPolicy(toolID: RuntimePolicyTool.id, actionID: "read", descriptorRevision: "r1", mode: policy)
        }
        let probe = RuntimePolicyProbe()
        let tool = RuntimePolicyTool(store: store, probe: probe, requiresApproval: requiresApproval,
            dependencyCheck: dependencyCheck)
        self.store = store; self.probe = probe; self.tool = tool
        runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [tool]), safetyCap: safetyCap)
    }

    func complete() async throws -> ToolExecutionResult? {
        try await runtime.complete(agentRunID: "r", providerCallID: "provider-call", toolID: RuntimePolicyTool.id,
            argumentsJSON: "{}", batchID: "batch", batchSequence: 0)
    }

    func call() throws -> ToolCallRecord {
        try #require(try store.toolCalls(inRun: "r").first)
    }

    func set(_ mode: ToolPersistentPolicy) throws {
        try store.setToolPolicy(toolID: RuntimePolicyTool.id, actionID: "read", descriptorRevision: "r1", mode: mode)
    }
}

private actor RuntimePolicyProbe {
    struct Entry: Sendable {
        let callID: String
        let observedState: ToolCallState?
    }
    private var observations: [Entry] = []
    func record(callID: String, state: ToolCallState?) { observations.append(Entry(callID: callID, observedState: state)) }
    func entries() -> [Entry] { observations }
}

private struct RuntimePolicyTool: ToolExecutable {
    static let id = "runtime_policy_probe"
    let store: PersistenceStore
    let probe: RuntimePolicyProbe
    var requiresApproval = false
    var dependencyCheck: @Sendable (PersistenceStore) throws -> Void = { _ in }

    var descriptor: ToolDescriptor {
        ToolDescriptor(id: Self.id, displayName: "Policy probe", description: "Local test operation",
            inputSchema: .object([:]), revision: "r1", sideEffect: .none,
            approvalRequirement: requiresApproval ? .required : .notRequired,
            actions: [ToolPolicyActionMetadata(toolID: Self.id, actionID: "read", descriptorRevision: "r1",
                risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true,
                resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolArgumentJSON.requireEmptyObject(argumentsJSON)
        return try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "read", normalizedArgumentsJSON: "{}",
            resource: .notRequired, destination: .notRequired,
            approvalDisclosure: ToolApprovalDisclosure(toolDisplayName: "Policy probe", action: "Read",
                targetDescription: "No external resource", keyImpact: "Local test operation"))
    }
    func validateDependencies(_ intent: ToolExecutionIntent) throws { try dependencyCheck(store) }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        await probe.record(callID: idempotencyKey, state: try store.toolCall(id: idempotencyKey)?.state)
        return ToolExecutionResult(content: "done")
    }
}
