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
