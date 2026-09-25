import Foundation
import GRDB
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
        try components.store.database.write { db in
            try Fixtures.message(
                id: "prompt-history-unlinked-user",
                conversationID: Stage2GateFixture.conversationID,
                role: .user,
                sequence: 2
            ).insert(db)
            try Fixtures.textPart(
                id: "prompt-history-unlinked-part",
                messageID: "prompt-history-unlinked-user",
                text: "Unlinked historical input"
            ).insert(db)
        }
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
        #expect(
            !requests[1].messages.contains(.user("Unlinked historical input")),
            "an orphan Message without a completed Parent Run must not enter history"
        )
    }

    @Test("reopened history stays scoped to its conversation and includes each quote once")
    func reopenedHistoryIsConversationScopedAndPreservesQuoteSnapshots() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-reopen.sqlite")
        defer { Fixtures.cleanUp(url) }

        let services = try await runInitialConversations(at: url)
        let requests = try await runFollowUpAfterReopening(at: url, services: services)
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }

        let system = systemContent(in: requests[0])
        #expect(
            requests[0].messages == [
                .system(system),
                .user("Conversation A first\n\nQuoted context:\nQuoted passage 1:\nFirst snapshot"),
            ]
        )
        #expect(
            requests[1].messages == [
                .system(system),
                .user("Conversation B question"),
            ],
            "another Conversation's messages must not enter this request"
        )
        #expect(
            requests[2].messages == [
                .system(system),
                .user("Conversation A first\n\nQuoted context:\nQuoted passage 1:\nFirst snapshot"),
                .assistant(content: "Answer A1", reasoning: nil, toolCalls: []),
                .user("Conversation A follow-up\n\nQuoted context:\nQuoted passage 1:\nCurrent snapshot"),
            ],
            "a rebuilt runtime must read persisted history and append the current quote once"
        )
    }

    @Test("history omits the entire turn that contains structured tool protocol")
    func historySkipsToolTurnsAsWholeUnits() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-tool-turn.sqlite")
        defer { Fixtures.cleanUp(url) }

        let requests = try await runToolConversation(at: url)
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }

        let system = systemContent(in: requests[0])
        let continuation = requests[1].messages
        #expect(
            continuation.contains {
                guard case .assistant(_, _, let calls) = $0 else { return false }
                return calls.contains { $0.id == "history-tool-call" }
            }
        )
        #expect(
            continuation.contains {
                guard case .toolResult(let callID, _) = $0 else { return false }
                return callID == "history-tool-call"
            },
            "the live continuation must retain the structured call/result pair"
        )

        #expect(
            requests[2].messages == [
                .system(system),
                .user("After tool turn"),
            ],
            "tool-bearing Turns are excluded atomically instead of flattened into text"
        )
        #expect(
            !requests[2].messages.contains {
                if case .toolResult = $0 { return true }
                if case .assistant(_, _, let calls) = $0 { return !calls.isEmpty }
                return false
            }
        )
    }

    private struct Services: Sendable {
        let credentials: CredentialStore
        let provider: Stage2ScriptedProvider
        let ledger: Stage2ProviderLedger
    }

    private func runInitialConversations(at url: URL) async throws -> Services {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        try insertQuoteSource(in: components.store)
        try components.store.database.write { db in
            try Fixtures.conversation(id: "prompt-history-other-conversation").insert(db)
        }

        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("Answer A1"), .finish(.stop)]),
                .events([.textDelta("Answer B1"), .finish(.stop)]),
                .events([.textDelta("Answer A2"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty
        )

        var first = Stage2GateFixture.command(text: "Conversation A first")
        first.references = [quote(id: "quote-a1", snapshot: "First snapshot")]
        _ = try await runtime.send(first)

        var other = Stage2GateFixture.command(text: "Conversation B question")
        other.conversationID = "prompt-history-other-conversation"
        _ = try await runtime.send(other)

        return Services(
            credentials: components.credentials,
            provider: provider,
            ledger: ledger
        )
    }

    private func runFollowUpAfterReopening(
        at url: URL,
        services: Services
    ) async throws -> [ProviderChatRequest] {
        let store = try Stage2GateFixture.reopen(url)
        let runtime = ConversationRuntime(
            store: store,
            provider: services.provider,
            credentials: services.credentials,
            toolRegistry: .empty
        )
        var followUp = Stage2GateFixture.command(text: "Conversation A follow-up")
        followUp.references = [quote(id: "quote-a2", snapshot: "Current snapshot")]
        _ = try await runtime.send(followUp)
        return await services.ledger.requestsSnapshot()
    }

    private func runToolConversation(at url: URL) async throws -> [ProviderChatRequest] {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "history-tool-call",
                        index: 0,
                        name: CalculatorTool.toolID,
                        argumentsJSON: #"{"expression":"6*7"}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("Tool turn answer"), .finish(.stop)]),
                .events([.textDelta("Follow-up answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: try ToolRegistry(tools: [CalculatorTool()])
        )
        _ = try await runtime.send(Stage2GateFixture.command(text: "Run calculator"))
        _ = try await runtime.send(Stage2GateFixture.command(text: "After tool turn"))
        return await ledger.requestsSnapshot()
    }

    private func insertQuoteSource(in store: PersistenceStore) throws {
        try store.database.write { db in
            try Fixtures.conversation(id: "prompt-history-quote-source").insert(db)
            try Fixtures.message(
                id: "prompt-history-quote-message",
                conversationID: "prompt-history-quote-source"
            ).insert(db)
            try MessagePartRecord(
                id: "prompt-history-quote-part",
                messageID: "prompt-history-quote-message",
                sequence: 0,
                kind: .text,
                state: .completed,
                payload: try PersistenceStore.encodeTextPayload(.init(text: "Source text"))
            ).insert(db)
        }
    }

    private func quote(id: String, snapshot: String) -> QuoteReference {
        QuoteReference(
            id: id,
            source: QuoteSourceLocator(
                sourceConversationID: "prompt-history-quote-source",
                sourceMessageID: "prompt-history-quote-message",
                sourcePartID: "prompt-history-quote-part",
                range: QuoteTextRange(utf16Start: 0, utf16Length: 6)
            ),
            snapshot: snapshot,
            createdAt: Fixtures.epoch
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
