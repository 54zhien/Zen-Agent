import Foundation
import Testing
@testable import ZenAgent

@Suite("Memory warm erasure authority")
struct MemoryErasureTests {
    @Test("Stop committed while a provider handoff is queued prevents its POST before the Stop projection returns", .timeLimit(.minutes(1)))
    func queuedHandoffStop() async throws {
        let writerEntered = MemoryTestLatch(), releaseWriter = MemoryTestLatch()
        let stoppingObserved = MemoryTestLatch(), releaseStoppingProjection = MemoryTestLatch()
        let fixture = try MemoryPromptFixture.make(onEvent: { event in
            if case .runStateChanged(_, .stopping) = event {
                await stoppingObserved.open(); await releaseStoppingProjection.wait()
            }
        })
        defer { Task { await releaseWriter.open(); await releaseStoppingProjection.open() } }
        let store = fixture.store
        let blocker = Task { await store.memoryAccessGate.withWrite { await writerEntered.open(); await releaseWriter.wait() } }
        await writerEntered.wait()
        let runID = try await fixture.runtime.start(fixture.command(text: "a queued request"),
            creatingConversationIfMissing: Fixtures.conversation(id: "memory-conversation"))
        for _ in 0..<1_000 {
            if try !store.steps(inRun: runID).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopping = Task { try await fixture.runtime.stop(runID: runID) }
        await stoppingObserved.wait()
        await releaseWriter.open(); await blocker.value
        for _ in 0..<1_000 {
            if !(await fixture.ledger.requestsSnapshot()).isEmpty { break }
            if try store.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.isEmpty)
        await releaseStoppingProjection.open()
        try await stopping.value
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(try store.run(id: runID)?.state == .cancelled)
    }

    @Test("a displayed tool approval cannot dispatch or continue after its Memory dependency was erased", .timeLimit(.minutes(1)))
    func pendingToolRevocation() async throws {
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let fixture = try MemoryPromptFixture.make(registry: ToolRegistry(tools: [tool]), scripts: [
            .events([.toolCall(.init(id: "memory-pending-call", index: 0, name: tool.descriptor.id, argumentsJSON: "{}")), .finish(.toolCalls)]),
            .events([.textDelta("unexpected continuation"), .finish(.stop)])
        ])
        let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        let item = try memory.save(content: "Windows project uses the managed tool")
        let runID = try await fixture.runtime.start(fixture.command(text: "Windows project action"),
            creatingConversationIfMissing: Fixtures.conversation(id: "memory-conversation"))
        var displayed: ToolApprovalProjection?
        for _ in 0..<1_000 {
            displayed = try await fixture.runtime.pendingToolApprovals(in: "memory-conversation").first
            if displayed != nil { break }
            if try fixture.store.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let displayed else {
            try await fixture.runtime.stop(runID: runID)
            try await fixture.runtime.waitForCompletion(runID: runID)
            Issue.record("Expected a real pending approval before erasure")
            return
        }
        try await memory.delete(id: item.id)
        try await fixture.runtime.resolveToolApproval(displayed.request(for: .approveOnce))
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(await effects.snapshot().isEmpty)
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.count == 1)
        #expect(try fixture.store.run(id: runID)?.endReason == .dependencyUnavailable)
    }

    @Test("editing and disabling Memory do not rewrite a frozen request during reconstruction")
    func frozenReconstruction() async throws {
        let fixture = try MemoryPromptFixture.make()
        let memory = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        let original = try memory.save(content: "Windows project uses OLD_FROZEN_VALUE")
        let runID = try await fixture.send(text: "Windows project")
        let stored = try fixture.store.run(id: runID)
        let run = try #require(stored)
        let encoded = try #require(run.executionSnapshot)
        let snapshot = try ExecutionSnapshotCodec.decode(encoded)
        _ = try memory.save(id: original.id, expectedRevisionID: original.revisionID, content: "Windows project uses NEW_CURRENT_VALUE")
        try memory.setEnabled(false)
        let request = try RunRequestRebuilder(store: fixture.store, provider: fixture.provider, toolRegistry: .empty)
            .initialRequest(for: run, snapshot: snapshot, history: [])
        guard let last = request.messages.last, case .user(let content) = last else { Issue.record("Missing reconstructed user context"); return }
        #expect(content.contains("OLD_FROZEN_VALUE"))
        #expect(!content.contains("NEW_CURRENT_VALUE"))
    }
}
