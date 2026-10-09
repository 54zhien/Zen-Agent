import Foundation
import Testing

@testable import ZenAgent

@Suite("S6-02 versioned tool intents")
struct ToolIntentVersionTests {
    @Test func builtinsFreezeExplicitV2ActionAndScopes() throws {
        let tools: [any ToolExecutable] = [CurrentDateTool(), CalculatorTool(), DeviceInfoTool()]
        for tool in tools {
            let arguments = tool.descriptor.id == "calculator" ? "{\"expression\":\"2+3\"}" : "{}"
            let intent = try tool.prepare(callID: "call", argumentsJSON: arguments)
            #expect(intent.formatVersion == 2)
            #expect(tool.descriptor.actions.count == 1)
            #expect(intent.policyAction != nil)
            #expect(intent.resourceScope == .notRequired)
            #expect(intent.destinationScope == .notRequired)
        }
    }

    @Test func frozenV2RoundTripsAndValidates() throws {
        let intent = S6IntentFixture.intent()
        let json = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        let restored = try ToolIntentCodec.decodeForDisplay(json)
        #expect(restored.policyAction?.actionID == "read")
        #expect(restored.resourceScope == .notRequired)
        try ToolIntentCodec.validate(restored, descriptor: S6IntentFixture.descriptor())
    }

    @Test func v1DecodesWithoutInventingAuthority() throws {
        let restored = try ToolIntentCodec.decodeForDisplay(S6IntentFixture.legacyJSON)
        #expect(restored.formatVersion == 1)
        #expect(restored.policyAction == nil)
        #expect(restored.resourceScope == nil)
        #expect(restored.destinationScope == nil)
        #expect(restored.approvalDisclosure?.action == "Historical read")
        #expect(throws: ToolIntentFailure.legacyIntentRequiresReapproval) {
            try ToolIntentCodec.validate(restored, descriptor: S6IntentFixture.descriptor())
        }
    }

    @Test(arguments: [0, 3, 999])
    func unsupportedVersionsCannotBecomeExecutable(version: Int) throws {
        var intent = S6IntentFixture.intent()
        intent.formatVersion = version
        let json = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        #expect(throws: ToolIntentFailure.unsupportedVersion) {
            try ToolIntentCodec.decodeForDisplay(json)
        }
        #expect(throws: ToolIntentFailure.unsupportedVersion) {
            try ToolIntentCodec.validate(intent, descriptor: S6IntentFixture.descriptor())
        }
    }

    @Test(arguments: ["{", "null", "{}", "{\"formatVersion\":2,\"toolID\":false}"])
    func corruptJSONHasStableFailure(json: String) {
        #expect(throws: ToolIntentFailure.malformedIntent) {
            try ToolIntentCodec.decodeForDisplay(json)
        }
    }

    @Test func changedDescriptorIsRejected() {
        var descriptor = S6IntentFixture.descriptor()
        descriptor.revision = "next"
        #expect(throws: ToolIntentFailure.descriptorChanged) {
            try ToolIntentCodec.validate(S6IntentFixture.intent(), descriptor: descriptor)
        }
    }

    @Test func sameRevisionCannotHideChangedActionMetadata() {
        var descriptor = S6IntentFixture.descriptor()
        descriptor.actions = [S6IntentFixture.action(risk: .destructive)]
        #expect(throws: ToolIntentFailure.actionChanged) {
            try ToolIntentCodec.validate(S6IntentFixture.intent(), descriptor: descriptor)
        }
    }

    @Test func missingMetadataDoesNotInferAllow() {
        var descriptor = S6IntentFixture.descriptor()
        descriptor.actions = []
        #expect(throws: ToolIntentFailure.actionChanged) {
            try ToolIntentCodec.validate(S6IntentFixture.intent(), descriptor: descriptor)
        }
    }

    @Test func missingV2ScopeIsNotNoResourceRequirement() {
        var intent = S6IntentFixture.intent()
        intent.resourceScope = nil
        #expect(throws: ToolIntentFailure.invalidScope) {
            try ToolIntentCodec.validate(intent, descriptor: S6IntentFixture.descriptor())
        }
    }

    @Test func legacyTargetCannotDisagreeWithFrozenScope() {
        var intent = S6IntentFixture.intent()
        intent.targetIdentity = "unexpected-target"
        #expect(throws: ToolIntentFailure.invalidScope) {
            try ToolIntentCodec.validate(intent, descriptor: S6IntentFixture.descriptor())
        }
    }

    @Test func opaqueToolIdentityUsesBytes() {
        var intent = S6IntentFixture.intent()
        intent.toolID = "e\u{301}"
        var descriptor = S6IntentFixture.descriptor()
        descriptor.id = "\u{e9}"
        #expect(throws: ToolIntentFailure.descriptorChanged) {
            try ToolIntentCodec.validate(intent, descriptor: descriptor)
        }
    }

    @Test(arguments: [ToolCallState.prepared, .approved])
    func legacyPendingSettlesOriginalCallWithoutExecution(state: ToolCallState) async throws {
        let store = try S6IntentFixture.store()
        let ledger = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: ledger)
        var intent = try tool.prepare(callID: "old", argumentsJSON: "{}")
        intent.formatVersion = 1
        intent.policyAction = nil
        intent.resourceScope = nil
        intent.destinationScope = nil
        let originalJSON = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        try store.createToolCall(S6IntentFixture.call(id: "old", state: state, json: originalJSON))
        let runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [tool]))
        do {
            if state == .approved { _ = try await runtime.executeApproved(toolCallID: "old") }
            else { _ = try await runtime.executePrepared(toolCallID: "old") }
        } catch { Issue.record("safe rejection must return its durable result, got \(error)") }
        #expect(await ledger.snapshot().isEmpty)
        #expect(try store.toolCalls(inRun: "s6-run").count == 1)
        #expect(try store.toolCall(id: "old")?.state == .rejected)
        #expect(try store.toolCall(id: "old")?.executionIntent == originalJSON)
        #expect(try store.toolResult(toolCallID: "old")?.payload == ToolIntentFailure.legacyIntentRequiresReapproval.resultContent)
    }

    @Test(arguments: ["{", "{\"formatVersion\":999,\"toolID\":\"current_date\",\"descriptorRevision\":\"1\",\"normalizedArgumentsJSON\":\"{}\"}"])
    func badStoredIntentSettlesWithoutNewCall(json: String) async throws {
        let store = try S6IntentFixture.store()
        try store.createToolCall(S6IntentFixture.call(id: "bad", state: .prepared, json: json, toolID: "current_date"))
        let runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [CurrentDateTool()]))
        do { _ = try await runtime.executePrepared(toolCallID: "bad") }
        catch { Issue.record("must return stable rejection, got \(error)") }
        #expect(try store.toolCall(id: "bad")?.state == .rejected)
        #expect(try store.toolCalls(inRun: "s6-run").count == 1)
        #expect(try store.toolResult(toolCallID: "bad") != nil)
    }
}

enum S6IntentFixture {
    static let legacyJSON = #"{"formatVersion":1,"toolID":"s6_tool","descriptorRevision":"1","normalizedArgumentsJSON":"{}","approvalDisclosure":{"toolDisplayName":"Old tool","action":"Historical read","targetDescription":"Old target","keyImpact":"Read once"}}"#

    static func action(risk: ToolActionRisk = .low) -> ToolPolicyActionMetadata {
        ToolPolicyActionMetadata(toolID: "s6_tool", actionID: "read", descriptorRevision: "1", risk: risk,
            allowsAutomaticApproval: true, allowsConversationGrant: true, resourceRequirement: .notRequired,
            egressRequirement: .notRequired)
    }

    static func descriptor() -> ToolDescriptor {
        ToolDescriptor(id: "s6_tool", displayName: "S6", description: "Test", inputSchema: .object([:]),
            revision: "1", sideEffect: .none, approvalRequirement: .notRequired, actions: [action()])
    }

    static func intent() -> ToolExecutionIntent {
        ToolExecutionIntent(formatVersion: 2, toolID: "s6_tool", descriptorRevision: "1", normalizedArgumentsJSON: "{}",
            targetIdentity: nil, destinationIdentity: nil, policyAction: action(), resourceScope: .notRequired,
            destinationScope: .notRequired)
    }

    static func store() throws -> PersistenceStore {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        _ = try store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "s6-conversation", messageID: "s6-message", runID: "s6-run", runState: .executingTools))
        return store
    }

    static func call(id: String, state: ToolCallState, json: String, toolID: String = "stage2_side_effect") -> ToolCallRecord {
        ToolCallRecord(id: id, agentRunID: "s6-run", action: toolID, state: state, executionIntent: json,
            attempt: 1, providerCallID: "provider-\(id)", batchID: "s6-batch", batchSequence: 0,
            createdAt: Fixtures.epoch, updatedAt: Fixtures.epoch)
    }
}
