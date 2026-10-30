import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 10 delegation runtime")
struct Stage10DelegationRuntimeTests {

    @Test("an enabled Parent delegates once and resumes with the persisted Child result")
    func parentDelegatesAndContinuesFromChildResult() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let childTask = "Summarize the requested change."
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "delegation-provider-call",
                        index: 0,
                        name: "subagent",
                        argumentsJSON: #"{"task":"Summarize the requested change."}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("child answer"), .finish(.stop)]),
                .events([.textDelta("parent answer"), .finish(.stop)]),
            ]
        )
        let events = Stage10DelegationEventLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { await events.append($0) }
        )
        try fixture.store.setDelegationEnabled(true)

        var command = I05RuntimeTestFixtures.command(modelID: Stage2GateFixture.modelID)
        command.text = "Review this change."
        command.conversationID = I05RuntimeTestFixtures.conversationID
        let parentRunID = try await runtime.start(command)
        let parentToolCallID = await events.waitForApproval()
        try await runtime.approve(toolCallID: parentToolCallID)
        try await runtime.waitForCompletion(runID: parentRunID)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let parentSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(parent.executionSnapshot)
        )
        #expect(parent.state == .completed)
        #expect(parentSnapshot.delegation?.enabled == true)
        #expect(parentSnapshot.delegation?.maxDepth == 1)
        #expect(parentSnapshot.delegation?.maxConcurrentChildren == 1)
        #expect(parentSnapshot.delegation?.modelPolicy == .followParent)
        #expect(parentSnapshot.delegation?.environmentInheritance == .none)
        #expect(parentSnapshot.exposedTools.contains { $0.toolID == "subagent" })

        let runs = try fixture.store.runs(inConversation: command.conversationID)
        let child = try #require(runs.first { $0.kind == .child })
        #expect(child.parentRunID == parentRunID)
        #expect(child.requestConfigSeed == parent.requestConfigSeed)
        #expect(child.state == .completed)
        let childSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(child.executionSnapshot)
        )
        #expect(!childSnapshot.modelCapabilities.contains(.tools))
        #expect(childSnapshot.exposedTools.isEmpty)
        #expect(childSnapshot.prompt.memoryReferences.isEmpty)
        #expect(childSnapshot.prompt.skillReferences.isEmpty)
        #expect(childSnapshot.delegation == nil)

        #expect(child.triggerMessageID == nil)
        let childResponseID = try #require(child.responseMessageID)
        let childAnswer = try fixture.store.parts(ofMessage: childResponseID)
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(childAnswer == "child answer")

        let parentCalls = try fixture.store.toolCalls(inRun: parentRunID)
        let delegationCall = try #require(parentCalls.first)
        #expect(delegationCall.state == .succeeded)
        let result = try #require(try fixture.store.toolResult(toolCallID: delegationCall.id))
        #expect(result.payload == "child answer")

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }
        #expect(requests[0].tools.contains { $0.name == "subagent" })
        #expect(requests[1].tools.isEmpty)
        #expect(requests[1].messages.compactMap { message -> String? in
            guard case .user(let text) = message else { return nil }
            return text
        } == [childTask])
        #expect(requests[2].messages.contains { message in
            guard case .toolResult(_, let content) = message else { return false }
            return content == "child answer"
        })

        let timeline = try ConversationTimelineLoader.load(
            conversationID: command.conversationID,
            from: fixture.store
        )
        #expect(timeline.turns.map(\.runID) == [parentRunID])
    }

    @Test("delegation is disabled until its runtime configuration is enabled")
    func delegationDefaultsDisabled() throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let configuration = try fixture.store.delegationConfiguration()

        #expect(!configuration.enabled)
        #expect(configuration.revision == 0)
    }
}

private actor Stage10DelegationEventLedger {
    private var approvalIDs: [String] = []
    private var approvalWaiters: [CheckedContinuation<String, Never>] = []

    func append(_ event: AgentEvent) {
        guard case .approvalRequired(_, let toolCallID) = event else { return }
        approvalIDs.append(toolCallID)
        let waiters = approvalWaiters
        approvalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: toolCallID)
        }
    }

    func waitForApproval() async -> String {
        if let toolCallID = approvalIDs.first { return toolCallID }
        return await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }
}
