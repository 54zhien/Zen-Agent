import Foundation
import Testing

@testable import ZenAgent

@Suite("Provider finish semantics")
@MainActor
struct AgentRuntimeFinishReasonTests {
    @Test(
        "incomplete semantic finishes preserve partial output as failed",
        arguments: [FinishReason.length, .contentFilter, .unknown("future_reason")]
    )
    func incompleteFinishFailsWithoutCompletingPart(_ reason: FinishReason) async throws {
        let url = try Fixtures.scratchPath(name: "finish-reason-\(UUID().uuidString).sqlite")
        defer { Fixtures.cleanUp(url) }
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let runtime = ConversationRuntime(
            store: components.store,
            provider: Stage2ScriptedProvider(
                ledger: ledger,
                scripts: [.events([.textDelta("partial answer"), .finish(reason)])]
            ),
            credentials: components.credentials,
            toolRegistry: .empty
        )

        let runID = try await runtime.send(Stage2GateFixture.command(text: "Question"))
        let run = try #require(try components.store.run(id: runID))
        #expect(run.state == .failed)
        #expect(run.endReason != .completed)
        let responseID = try #require(run.responseMessageID)
        let part = try #require(try components.store.parts(ofMessage: responseID).first)
        #expect(part.state == .failed)
        #expect(try components.store.text(ofPart: part.id) == "partial answer")
        #expect(try components.store.activeParentRuns(
            inConversation: Stage2GateFixture.conversationID
        ).isEmpty)
        #expect((await ledger.requestsSnapshot()).count == 1)
    }

    @Test("EOF without a semantic finish cannot complete an answer")
    func normalEOFFailsClosed() async throws {
        let url = try Fixtures.scratchPath(name: "finish-eof-\(UUID().uuidString).sqlite")
        defer { Fixtures.cleanUp(url) }
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let runtime = ConversationRuntime(
            store: components.store,
            provider: Stage2ScriptedProvider(
                ledger: Stage2ProviderLedger(),
                scripts: [.events([.textDelta("unterminated")])]
            ),
            credentials: components.credentials,
            toolRegistry: .empty
        )

        let runID = try await runtime.send(Stage2GateFixture.command(text: "Question"))
        let run = try #require(try components.store.run(id: runID))
        #expect(run.state == .failed)
        #expect(run.endReason == .providerFailed)
        let responseID = try #require(run.responseMessageID)
        let part = try #require(try components.store.parts(ofMessage: responseID).first)
        #expect(part.state == .failed)
        #expect(try components.store.text(ofPart: part.id) == "unterminated")
    }
}
