import Foundation
import Testing

@testable import ZenAgent

@Suite("Provider finish semantics")
@MainActor
struct AgentRuntimeFinishReasonTests {
    @Test(
        "incomplete semantic finishes preserve partial output as failed",
        arguments: [
            FinishReason.length,
            .contentFilter,
            .interrupted,
            .unknown("future_reason"),
        ]
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
                scripts: [
                    .events([.textDelta("partial answer"), .finish(reason)]),
                    .events([.textDelta("complete answer"), .finish(.stop)]),
                ]
            ),
            credentials: components.credentials,
            toolRegistry: .empty
        )

        let runID = try await runtime.send(Stage2GateFixture.command(text: "Question"))
        let run = try #require(try components.store.run(id: runID))
        #expect(run.state == .failed)
        let expectedReason: EndReason
        let expectedNotice: String
        switch reason {
        case .length:
            expectedReason = .outputLimit
            expectedNotice = "回答达到长度限制，已保留已生成内容。"
        case .contentFilter:
            expectedReason = .contentFiltered
            expectedNotice = "回答因内容过滤而结束。"
        case .interrupted:
            expectedReason = .providerInterrupted
            expectedNotice = "模型生成被中断，已保留已生成内容。"
        default:
            expectedReason = .providerFailed
            expectedNotice = "模型未正常结束本次回答。"
        }
        #expect(run.endReason == expectedReason)
        let responseID = try #require(run.responseMessageID)
        let part = try #require(try components.store.parts(ofMessage: responseID).first)
        #expect(part.state == .failed)
        #expect(try components.store.text(ofPart: part.id) == "partial answer")
        #expect(try components.store.activeParentRuns(
            inConversation: Stage2GateFixture.conversationID
        ).isEmpty)
        let runtimeProjection = try await runtime.projection(
            conversationID: Stage2GateFixture.conversationID
        )
        #expect(runtimeProjection?.endReason == expectedReason)
        let reopened = try Stage2GateFixture.reopen(url)
        #expect(try reopened.run(id: runID)?.endReason == expectedReason)
        let timeline = try ConversationTimelineLoader.load(
            conversationID: Stage2GateFixture.conversationID,
            from: reopened
        )
        let turn = try #require(timeline.turns.first { $0.runID == runID })
        #expect(turn.items.contains(.assistantText("partial answer")))
        #expect(turn.items.contains(.runNotice(RunNoticePresentation(
            runID: runID,
            state: .failed,
            endReason: expectedReason
        ))))
        let notice = try #require(turn.items.compactMap { item -> RunNoticePresentation? in
            if case .runNotice(let notice) = item { return notice }
            return nil
        }.first)
        #expect(notice.explanation == expectedNotice)

        _ = try await runtime.send(Stage2GateFixture.command(text: "Next question"))
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        let nextMessages = try #require(requests.last?.messages)
        #expect(nextMessages.contains(.user("Next question")))
        #expect(!nextMessages.contains(.user("Question")))
        #expect(!nextMessages.contains(.assistant(
            content: "partial answer",
            reasoning: nil,
            toolCalls: []
        )))
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

    @Test(
        "a conflicting finish never authorizes an incomplete tool fragment",
        arguments: [
            Optional<FinishReason>.none,
            .some(.stop),
            .some(.length),
            .some(.contentFilter),
            .some(.interrupted),
            .some(.unknown("future_reason")),
        ]
    )
    func conflictingFinishDoesNotDispatchTool(_ reason: FinishReason?) async throws {
        let url = try Fixtures.scratchPath(name: "finish-tool-\(UUID().uuidString).sqlite")
        defer { Fixtures.cleanUp(url) }
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let sideEffects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: sideEffects)
        let call = ProviderToolCall(
            id: "provider-call",
            index: 0,
            name: tool.descriptor.id,
            argumentsJSON: "{}"
        )
        var events: [ProviderStreamEvent] = [.toolCall(call)]
        if let reason { events.append(.finish(reason)) }
        let runtime = ConversationRuntime(
            store: components.store,
            provider: Stage2ScriptedProvider(
                ledger: Stage2ProviderLedger(),
                scripts: [.events(events)]
            ),
            credentials: components.credentials,
            toolRegistry: try ToolRegistry(tools: [tool])
        )

        let runID = try await runtime.send(Stage2GateFixture.command(text: "Use the tool"))
        #expect(try components.store.run(id: runID)?.state == .failed)
        #expect(try components.store.toolCalls(inRun: runID).isEmpty)
        #expect((await sideEffects.snapshot()).isEmpty)
        #expect(try components.store.activeParentRuns(
            inConversation: Stage2GateFixture.conversationID
        ).isEmpty)
    }
}
