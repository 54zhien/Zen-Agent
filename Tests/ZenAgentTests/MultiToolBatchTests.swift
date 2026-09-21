import Foundation
import Testing

@testable import ZenAgent

@Suite("Multi-tool batch continuation")
struct MultiToolBatchTests {
    @Test("all calls in one provider response settle before continuation")
    func waitsForTheWholeBatch() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: "{\"value\":0}"
                    )),
                    .toolCall(.init(
                        id: "provider-call-1",
                        index: 1,
                        name: "echo",
                        argumentsJSON: "{\"value\":1}"
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("batch complete"),
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
        let linkedIDs = parts
            .filter { $0.kind == .toolCall || $0.kind == .toolResult }
            .compactMap { part -> String? in
                guard let data = part.payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? [String: Any]
                else { return nil }
                return dictionary["toolCallID"] as? String
            }
        let text = parts.compactMap { try? fixture.store.text(ofPart: $0.id) }.joined()
        let requestCount = await ledger.requestCount()

        #expect(
            requestCount == 2 &&
                run?.state == .completed &&
                text == "batch complete" &&
                linkedIDs.count == 4 &&
                linkedIDs.filter { $0 == "provider-call-0" }.count == 2 &&
                linkedIDs.filter { $0 == "provider-call-1" }.count == 2
        )
    }
}
