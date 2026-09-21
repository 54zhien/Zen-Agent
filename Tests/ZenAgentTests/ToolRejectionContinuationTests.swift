import Foundation
import Testing

@testable import ZenAgent

@Suite("Tool rejection continuation")
struct ToolRejectionContinuationTests {
    @Test("rejecting one call still lets the completed batch continue")
    func rejectionIsModelVisibleAndNotRunTerminal() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let eventLedger = I07EventLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-rejected",
                        index: 0,
                        name: "approval-required",
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("continued after rejection"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger
            ),
            I07RecordingTool(
                id: "approval-required",
                approvalRequirement: .required,
                ledger: toolLedger
            ),
        ])
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in await eventLedger.append(event) },
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        let approvalID = await eventLedger.waitForApproval()
        let waitingCalls = try fixture.store.toolCalls(inRun: runID)

        #expect(waitingCalls.count == 1)
        guard let waitingCall = waitingCalls.first else {
            #expect(false, "approval must create a durable ToolCall")
            return
        }
        #expect(approvalID == waitingCall.id)
        #expect(waitingCall.providerCallID == "provider-call-rejected")
        #expect(waitingCall.batchID != nil && !(waitingCall.batchID?.isEmpty ?? true))
        #expect(waitingCall.batchSequence == 0)
        #expect(waitingCall.state == .waitingForApproval)
        #expect(waitingCall.executionIntent != nil)

        try await runtime.reject(toolCallID: approvalID)
        try await runtime.waitForCompletion(runID: runID)

        let run = try fixture.store.run(id: runID)
        let requests = await ledger.requestsSnapshot()
        let invocations = await toolLedger.snapshot()
        let assistantMessages = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .assistant }

        #expect(requests.count == 2)
        #expect(run?.state == .completed)
        #expect(assistantMessages.count == 1)
        #expect(invocations.isEmpty)

        guard let responseID = run?.responseMessageID else {
            #expect(false, "the completed run must point to its assistant response")
            return
        }
        guard let assistant = assistantMessages.first else {
            #expect(false, "the rejection continuation must materialize an assistant response")
            return
        }
        #expect(responseID == assistant.id)

        let parts = try fixture.store.parts(ofMessage: assistant.id)
        let text = try parts
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(text == "continued after rejection")

        let calls = try fixture.store.toolCalls(inRun: runID)
        #expect(calls.count == 1)
        guard let call = calls.first else {
            #expect(false, "the rejected call must remain the only ToolCall")
            return
        }
        #expect(call.id == approvalID)
        #expect(call.providerCallID == "provider-call-rejected")
        #expect(call.batchID != nil && !(call.batchID?.isEmpty ?? true))
        #expect(call.batchSequence == 0)
        #expect(call.state == .rejected)

        let expectedRejection = "Tool execution was rejected by the user."
        guard let result = try fixture.store.toolResult(toolCallID: call.id) else {
            #expect(false, "a rejection must persist a model-visible ToolResult")
            return
        }
        #expect(result.toolCallID == call.id)
        #expect(result.payload == expectedRejection)

        guard requests.count > 1 else {
            #expect(false, "the rejection must be sent in a continuation request")
            return
        }
        let continuationResults = requests[1].messages.compactMap {
            message -> (toolCallID: String, content: String)? in
            guard case .toolResult(let toolCallID, let content) = message else {
                return nil
            }
            return (toolCallID, content)
        }
        #expect(continuationResults.count == 1)
        #expect(continuationResults.first?.toolCallID == "provider-call-rejected")
        #expect(continuationResults.first?.content == expectedRejection)

        let callParts = parts.filter { $0.kind == .toolCall }
        let resultParts = parts.filter { $0.kind == .toolResult }
        #expect(callParts.count == 1)
        #expect(resultParts.count == 1)
        if let callPart = callParts.first {
            let payload = try JSONDecoder().decode(
                ToolCallPartPayload.self,
                from: Data(callPart.payload.utf8)
            )
            #expect(payload.toolCallID == call.id)
        }
        if let resultPart = resultParts.first {
            let payload = try JSONDecoder().decode(
                ToolResultPartPayload.self,
                from: Data(resultPart.payload.utf8)
            )
            #expect(payload.toolCallID == call.id)
        }
    }
}
