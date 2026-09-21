import Foundation
import Testing

@testable import ZenAgent

@Suite("Tool rejection continuation")
struct ToolRejectionContinuationTests {
    @Test("rejecting one call still lets the completed batch continue")
    func rejectionIsModelVisibleAndNotRunTerminal() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
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
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let run = try fixture.store.run(id: runID)
        let assistant = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).first { $0.role == .assistant }
        let parts = try assistant.map { try fixture.store.parts(ofMessage: $0.id) } ?? []
        let rejectionPayload = parts
            .filter { $0.kind == .toolResult }
            .compactMap { $0.payload }
            .joined(separator: "\n")
        let text = parts.compactMap { try? fixture.store.text(ofPart: $0.id) }.joined()
        let requestCount = await ledger.requestCount()

        #expect(
            requestCount == 2 &&
                run?.state == .completed &&
                text == "continued after rejection" &&
                rejectionPayload.localizedCaseInsensitiveContains("rejected")
        )
    }
}
