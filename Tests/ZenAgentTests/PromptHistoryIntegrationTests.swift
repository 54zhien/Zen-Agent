import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation prompt history")
struct PromptHistoryIntegrationTests {

    @Test("real sends include system instructions and the prior completed text turn")
    func realSendsComposeSystemAndPriorTextHistory() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-text-turns.sqlite")
        defer { Fixtures.cleanUp(url) }

        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("First answer"), .finish(.stop)]),
                .events([.textDelta("Second answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty
        )

        _ = try await runtime.send(Stage2GateFixture.command(text: "First question"))
        _ = try await runtime.send(Stage2GateFixture.command(text: "Second question"))

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }

        let firstSystem = systemContent(in: requests[0])
        #expect(firstSystem.contains("Runtime / Safety"))
        #expect(firstSystem.contains("Provider Adapter"))
        #expect(firstSystem.contains("Zen Core defaults"))
        #expect(requests[0].messages.last == .user("First question"))

        #expect(
            requests[1].messages == [
                .system(firstSystem),
                .user("First question"),
                .assistant(content: "First answer", reasoning: nil, toolCalls: []),
                .user("Second question"),
            ],
            "the provider must receive ordered persisted text history plus the current input"
        )
    }

    private func systemContent(in request: ProviderChatRequest) -> String {
        guard let first = request.messages.first,
              case .system(let content) = first
        else {
            Issue.record("the provider request must begin with the composed system message")
            return ""
        }
        return content
    }
}

