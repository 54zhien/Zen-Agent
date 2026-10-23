import Foundation
import Testing
@testable import ZenAgent

@Suite("Runtime policy continuation")
struct ToolPolicyContinuationTests {
    @Test("policy denial remains a result in the original provider batch", .timeLimit(.minutes(1)))
    func deniedThenAllowedCallContinuesProvider() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let registry = try Fixtures.automaticallyAllowedRegistry(in: fixture.store,
            tools: [CalculatorTool(), CurrentDateTool()])
        try fixture.store.setToolPolicy(toolID: "calculator", actionID: "calculator",
            descriptorRevision: "1", mode: .deny)
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: fixture.instance.id, scripts: [
            [.toolCall(.init(id: "denied", index: 0, name: "calculator", argumentsJSON: "{\"expression\":\"2+3\"}")),
             .toolCall(.init(id: "allowed", index: 1, name: "current_date", argumentsJSON: "{}")), .finish(.toolCalls)],
            [.textDelta("continued"), .finish(.stop)]
        ], toolLedger: I07ToolLedger(), store: fixture.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: fixture.store, provider: provider,
            credentials: fixture.credentials, toolRegistry: registry)
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        try await Fixtures.awaitRuntimeCompletion(in: fixture.store, runtime: runtime, runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        let calls = try fixture.store.toolCalls(inRun: runID).sorted { ($0.batchSequence ?? 0) < ($1.batchSequence ?? 0) }
        #expect(calls.map(\.state) == [.rejected, .succeeded])
        #expect(calls.first?.failureReason == .policyDenied)
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        if requests.count == 2 {
            let ids = requests[1].messages.compactMap { message -> String? in
                guard case .toolResult(let id, _) = message else { return nil }; return id
            }
            #expect(ids == ["denied", "allowed"])
        }
    }

    @Test("revoked approval reannounces the same call and resumes after a second decision", .timeLimit(.minutes(1)))
    func revokedApprovalKeepsTheOwningWaiter() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let providerLedger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let events = PolicyApprovalEvents()
        let tool = RevokeFirstApprovalTool(store: fixture.store,
            base: I07RecordingTool(id: "reapprove", approvalRequirement: .required, ledger: toolLedger))
        let provider = I07ScriptedProvider(ledger: providerLedger, instanceID: fixture.instance.id, scripts: [
            [.toolCall(.init(id: "original-provider-call", index: 0, name: "reapprove", argumentsJSON: "{}")), .finish(.toolCalls)],
            [.textDelta("continued"), .finish(.stop)]
        ], toolLedger: toolLedger, store: fixture.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: fixture.store, provider: provider, credentials: fixture.credentials,
            onEvent: { await events.append($0) }, toolRegistry: try ToolRegistry(tools: [tool]))
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        try await waitForApprovals(1, events: events)
        let original = try #require(try fixture.store.toolCalls(inRun: runID).first)
        try await runtime.approve(toolCallID: original.id)
        try await waitForApprovals(2, events: events)
        #expect(try fixture.store.toolCall(id: original.id)?.state == .waitingForApproval)
        #expect(await toolLedger.snapshot().isEmpty)
        try await runtime.approve(toolCallID: original.id)
        try await Fixtures.awaitRuntimeCompletion(in: fixture.store, runtime: runtime, runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        let calls = try fixture.store.toolCalls(inRun: runID)
        #expect(calls.map(\.id) == [original.id])
        #expect(calls.first?.executionIntent == original.executionIntent)
        #expect(calls.first?.state == .succeeded)
        #expect(await toolLedger.snapshot().count == 1)
        #expect(await events.ids() == [original.id, original.id])
        #expect(await providerLedger.requestsSnapshot().count == 2)
    }

    private func waitForApprovals(_ count: Int, events: PolicyApprovalEvents) async throws {
        for _ in 0..<1000 {
            if await events.ids().count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PolicyApprovalTimeout()
    }
}

private struct PolicyApprovalTimeout: Error {}
private actor PolicyApprovalEvents {
    private var calls: [String] = []
    func append(_ event: AgentEvent) {
        if case .approvalRequired(_, let id) = event { calls.append(id) }
    }
    func ids() -> [String] { calls }
}

/// A single controlled mutation between approval and dispatch. The executor and
/// owning Runtime are the real production paths; only this dependency is synthetic.
private final class RevokeFirstApprovalTool: ToolExecutable, @unchecked Sendable {
    let store: PersistenceStore
    let base: I07RecordingTool
    private let lock = NSLock()
    private var didRevoke = false
    var descriptor: ToolDescriptor { base.descriptor }
    init(store: PersistenceStore, base: I07RecordingTool) { self.store = store; self.base = base }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try base.prepare(callID: callID, argumentsJSON: argumentsJSON)
    }
    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        try base.validateDependencies(intent)
        try lock.withLock {
            guard !didRevoke,
                  let grant = try store.toolGrants(subject: .parentConversation(I05RuntimeTestFixtures.conversationID))
                    .first(where: { $0.grant.validity == .active }) else { return }
            _ = try store.revokeToolGrant(id: grant.id)
            didRevoke = true
        }
    }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        try await base.execute(intent, idempotencyKey: idempotencyKey)
    }
}
