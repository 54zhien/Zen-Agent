import Foundation
import Testing
@testable import ZenAgent

@Suite("S6-04b system consent boundary")
struct ToolSystemPermissionTests {
    @Test func alwaysAllowCannotRequestOrExecuteBeforeUserConsent() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        #expect(try await f.complete() == nil)
        #expect(try f.call().state == .waitingForSystemPermissionConsent)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
    }

    @Test func toolApprovalStillPrecedesSystemConsent() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined, policy: .askEveryTime)
        #expect(try await f.complete() == nil)
        #expect(try f.call().state == .waitingForApproval)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
    }

    @Test(arguments: [ToolSystemPermissionState.denied, .restricted, .unavailable])
    func unavailableSystemAccessNeverDispatches(status: ToolSystemPermissionState) async throws {
        let f = try SystemPermissionFixture(status: status)
        _ = try await f.complete()
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolResult(toolCallID: f.call().id) != nil)
    }

    @Test(arguments: [ToolSystemPermissionState.authorized, .notRequired])
    func availableAccessStillCommitsBeforeExecution(status: ToolSystemPermissionState) async throws {
        let f = try SystemPermissionFixture(status: status)
        #expect(try await f.complete()?.content == "permission-result")
        #expect(try f.call().state == .succeeded)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 1)
        #expect(await f.driver.observedDispatch)
    }

    @Test func explicitConsentRequestsOnceWithoutIssuingGrant() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let original = try f.call()
        try #require(original.state == .waitingForSystemPermissionConsent)
        try await f.runtime.resolveSystemPermission(toolCallID: original.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(original.executionIntent)), consent: true)
        #expect(await f.driver.requests == 1)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
        #expect(try f.call().id == original.id)
        #expect(try f.call().executionIntent == original.executionIntent)
        #expect(try f.call().state == .prepared)
        _ = try await f.runtime.executePrepared(toolCallID: original.id)
        #expect(await f.driver.executions == 1)
        #expect(await f.driver.observedDispatch)
    }

    @Test func decliningConsentNeverRequestsAndSettlesOriginalCall() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        try #require(call.state == .waitingForSystemPermissionConsent)
        try await f.runtime.resolveSystemPermission(toolCallID: call.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), consent: false)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolResult(toolCallID: call.id) != nil)
    }

    @Test func permissionRevocationAfterApprovalIsCheckedBeforeDispatch() async throws {
        let f = try SystemPermissionFixture(status: .authorized, policy: .askEveryTime)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        await f.driver.set(.denied)
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.executions == 0)
    }

    @Test func settingsTighteningBlocksSystemRequestFromOldCard() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        try #require(call.state == .waitingForSystemPermissionConsent)
        try f.store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: .deny)
        try await f.runtime.resolveSystemPermission(toolCallID: call.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), consent: true)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
    }
}

private struct SystemPermissionFixture: Sendable {
    let store: PersistenceStore
    let driver: SystemPermissionDriver
    let runtime: ToolRuntime
    init(status: ToolSystemPermissionState, policy: ToolPersistentPolicy = .alwaysAllow) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        try store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: policy)
        let driver = SystemPermissionDriver(status: status)
        self.store = store; self.driver = driver
        runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [SystemPermissionProbe(store: store, driver: driver)]))
    }
    func complete() async throws -> ToolExecutionResult? {
        try await runtime.complete(agentRunID: "r", providerCallID: "pc", toolID: "system_probe",
            argumentsJSON: "{}", batchID: "b", batchSequence: 0)
    }
    func call() throws -> ToolCallRecord { try #require(try store.toolCalls(inRun: "r").first) }
}

private actor SystemPermissionDriver {
    var status: ToolSystemPermissionState
    var requests = 0
    var executions = 0
    var observedDispatch = false
    init(status: ToolSystemPermissionState) { self.status = status }
    func set(_ value: ToolSystemPermissionState) { status = value }
    func request() { requests += 1; status = .authorized }
    func execute(dispatched: Bool) { executions += 1; observedDispatch = dispatched }
}

private struct SystemPermissionProbe: ToolSystemPermissionProviding {
    let store: PersistenceStore
    let driver: SystemPermissionDriver
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "system_probe", displayName: "Test capability", description: "Test-only capability",
            inputSchema: .object([:]), revision: "1", sideEffect: .none, approvalRequirement: .notRequired,
            actions: [ToolPolicyActionMetadata(toolID: "system_probe", actionID: "probe", descriptorRevision: "1",
                risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true,
                resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }
    var systemPermissionDescription: String { "Test-only operating system capability" }
    func systemPermissionState(for intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState { await driver.status }
    func requestSystemPermission(for intent: ToolExecutionIntent) async throws { await driver.request() }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolIntentCodec.makeIntent(descriptor: descriptor, actionID: "probe", normalizedArgumentsJSON: "{}",
            resource: .notRequired, destination: .notRequired,
            disclosure: ToolApprovalDisclosure(toolDisplayName: "Test capability", action: "Probe", targetDescription: "Local test",
                keyImpact: "Test-only request"))
    }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        await driver.execute(dispatched: try store.toolCall(id: idempotencyKey)?.state == .dispatched)
        return ToolExecutionResult(content: "permission-result")
    }
}
