import Foundation
import Testing

@testable import ZenAgent

@Suite("Callable tool Settings")
@MainActor
struct ToolSettingsTests {
    @Test func builtinsProvideCompleteFrozenApprovalDisclosure() throws {
        let tools: [any ToolExecutable] = [CalculatorTool(), CurrentDateTool(),
            DeviceInfoTool(snapshot: .init(osFamily: "iOS", osVersion: "26", deviceIdiom: "phone", genericModelClass: "phone"))]
        for tool in tools {
            let args = tool.descriptor.id == "calculator" ? "{\"expression\":\"1+1\"}" : "{}"
            let intent = try tool.prepare(callID: "disclosure-control", argumentsJSON: args)
            #expect(intent.approvalDisclosure?.isComplete == true)
        }
    }

    @Test func actualRegistryAndPersistentPolicyAreDisplayed() async throws {
        let f = try ToolSettingsFixture()
        let model = ToolSettingsModel(store: f.store, registry: f.registry)
        await model.load()
        let row = try #require(model.actions.first)
        #expect(row.toolID == "calculator")
        #expect(row.policy.mode == .askEveryTime)
        #expect(row.systemState == .notRequired)
        #expect(await model.setPolicy(toolID: row.toolID, actionID: row.action.actionID,
            descriptorRevision: row.action.descriptorRevision, mode: .deny))
        #expect(try f.store.toolPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1").mode == .deny)
        let reopened = ToolSettingsModel(store: f.store, registry: f.registry)
        await reopened.load()
        #expect(reopened.actions.first?.policy.mode == .deny)
    }

    @Test func revocationAddressesOriginalGrantAndBlocksOldApproval() async throws {
        let f = try ToolSettingsFixture()
        let call = try await f.waitingCall()
        try f.runtime.approve(toolCallID: call.id, displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), scope: .conversation)
        let model = ToolSettingsModel(store: f.store, registry: f.registry)
        await model.load()
        let row = try #require(model.grants.first)
        #expect(row.grant.subject == .parentConversation("c"))
        #expect(row.grant.kind == .conversation)
        #expect(row.grant.issuedFor?.toolCallID == call.id)
        #expect(await model.revokeGrant(id: row.id))
        #expect(try f.store.toolGrant(id: row.id)?.validity == .revoked)
        do { _ = try await f.runtime.executeApproved(toolCallID: call.id) } catch { }
        #expect(try f.store.toolCall(id: call.id)?.state == .waitingForApproval)
        #expect(try f.store.toolResult(toolCallID: call.id) == nil)
        await model.load()
        #expect(model.grants.first?.invalidationReason != nil)
    }

    @Test func tighteningThenWideningDoesNotReleaseTheOldCard() async throws {
        let f = try ToolSettingsFixture()
        let call = try await f.waitingCall()
        let model = ToolSettingsModel(store: f.store, registry: f.registry)
        #expect(await model.setPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1", mode: .deny))
        #expect(await model.setPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1", mode: .alwaysAllow))
        _ = try f.runtime.validatePendingIntent(toolCallID: call.id)
        #expect(try f.store.toolCall(id: call.id)?.state == .waitingForApproval)
        #expect(try f.store.toolResult(toolCallID: call.id) == nil)
    }

    @Test(arguments: [true, false])
    func invalidationCauseComesFromTheOwningTransaction(policy: Bool) async throws {
        let f = try ToolSettingsFixture()
        let call = try await f.waitingCall()
        try f.runtime.approve(toolCallID: call.id, displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), scope: .conversation)
        if policy {
            try f.store.setToolPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1", mode: .deny)
        } else {
            try f.store.transitionRun(id: "r", expectedState: .executingTools, to: .failed, endReason: .providerFailed)
            try f.store.beginDeletion(conversationID: "c")
        }
        let model = ToolSettingsModel(store: f.store, registry: f.registry)
        await model.load()
        let grant = try #require(model.grants.first)
        #expect(grant.grant.validity == .revoked)
        #expect(grant.invalidationReason?.contains(policy ? "策略" : "主体") == true)
    }

    @Test func unavailableExecutorCannotBePresentedAsCallableButOldGrantsStayRevocable() async throws {
        let f = try ToolSettingsFixture()
        let call = try await f.waitingCall()
        try f.runtime.approve(toolCallID: call.id, displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), scope: .conversation)
        let model = ToolSettingsModel(store: f.store, registry: .empty)
        await model.load()
        #expect(model.actions.isEmpty)
        #expect(await model.setPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1", mode: .alwaysAllow) == false)
        let grant = try #require(model.grants.first)
        #expect(await model.revokeGrant(id: grant.id))
        #expect(try f.store.toolGrant(id: grant.id)?.validity == .revoked)
    }

    @Test func changedActionVersionRequiresReconfirmationInGrantDisclosure() async throws {
        let f = try ToolSettingsFixture()
        try f.store.setToolPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "1", mode: .askEveryTime)
        let call = try await f.waitingCall()
        try f.runtime.approve(toolCallID: call.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), scope: .conversation)
        let model = ToolSettingsModel(store: f.store, registry: try ToolRegistry(tools: [RevisedSettingsCalculator()]))
        await model.load()
        let row = try #require(model.grants.first)
        #expect(row.grant.descriptorRevision == "1")
        #expect(row.invalidationReason?.contains("需要重新确认") == true)
        #expect(model.actions.first?.policy.descriptorRevision == "1")
        #expect(try f.store.toolGrant(id: row.id)?.descriptorRevision == "1")
        #expect(await model.revokeGrant(id: row.id))
        #expect(await model.setPolicy(toolID: "calculator", actionID: "calculator", descriptorRevision: "2", mode: .askEveryTime))
        #expect(model.actions.first?.policy.descriptorRevision == "2")
        #expect(try f.store.toolGrant(id: row.id)?.validity == .revoked)
    }
}

private struct RevisedSettingsCalculator: ToolExecutable {
    var descriptor: ToolDescriptor {
        var value = CalculatorTool().descriptor
        value.revision = "2"
        value.actions = [.init(toolID: value.id, actionID: "calculator", descriptorRevision: value.revision,
            risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true,
            resourceRequirement: .notRequired, egressRequirement: .notRequired)]
        return value
    }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent { throw ToolIntentFailure.preparationFailed }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult { throw ToolIntentFailure.preparationFailed }
}

@MainActor
private struct ToolSettingsFixture {
    let store: PersistenceStore
    let registry: ToolRegistry
    let runtime: ToolRuntime
    init() throws {
        store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        registry = try ToolRegistry(tools: [CalculatorTool()])
        runtime = ToolRuntime(store: store, registry: registry)
    }
    func waitingCall() async throws -> ToolCallRecord {
        _ = try await runtime.complete(agentRunID: "r", providerCallID: "pc", toolID: "calculator", argumentsJSON: "{\"expression\":\"1+1\"}", batchID: "b", batchSequence: 0)
        let call = try #require(try store.toolCalls(inRun: "r").first)
        try #require(call.state == .waitingForApproval)
        return call
    }
}
