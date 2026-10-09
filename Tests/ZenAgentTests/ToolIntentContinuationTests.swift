import Foundation
import Testing

@testable import ZenAgent

@Suite("S6-02 intent validation continuation")
struct ToolIntentContinuationTests {
    @Test func invalidArgumentsPersistStableOriginalResult() async throws {
        let store = try S6IntentFixture.store()
        let runtime = ToolRuntime(store: store, registry: try ToolRegistry(tools: [CalculatorTool()]))
        do {
            _ = try await runtime.complete(agentRunID: "s6-run", providerCallID: "invalid", toolID: "calculator",
                argumentsJSON: "{\"secret\":\"never disclose\"}", batchID: "batch", batchSequence: 0)
        } catch { Issue.record("validation rejection must be a durable result, got \(error)") }
        let calls = try store.toolCalls(inRun: "s6-run")
        #expect(calls.count == 1)
        if let call = calls.first {
            #expect(call.state == .rejected)
            #expect(call.providerCallID == "invalid")
            #expect(try store.toolResult(toolCallID: call.id)?.payload == ToolIntentFailure.invalidArguments.resultContent)
        }
    }

    @Test func invalidThenValidCallsReachProviderContinuation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: fixture.instance.id, scripts: [
            [.toolCall(.init(id: "invalid", index: 0, name: "calculator", argumentsJSON: "{\"wrong\":true}")),
             .toolCall(.init(id: "valid", index: 1, name: "calculator", argumentsJSON: "{\"expression\":\"2+3\"}")),
             .finish(.toolCalls)], [.textDelta("continued"), .finish(.stop)]
        ], toolLedger: I07ToolLedger(), store: fixture.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: fixture.store, provider: provider, credentials: fixture.credentials,
            toolRegistry: try ToolRegistry(tools: [CalculatorTool()]))
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        try await runtime.waitForCompletion(runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        let calls = try fixture.store.toolCalls(inRun: runID).sorted { ($0.batchSequence ?? 0) < ($1.batchSequence ?? 0) }
        #expect(calls.count == 2)
        #expect(calls.map(\.state) == [.rejected, .succeeded])
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        if requests.count == 2 {
            let results = requests[1].messages.compactMap { message -> String? in
                guard case .toolResult(_, let content) = message else { return nil }
                return content
            }
            #expect(results == [ToolIntentFailure.invalidArguments.resultContent, "5.0"])
        }
    }
}
