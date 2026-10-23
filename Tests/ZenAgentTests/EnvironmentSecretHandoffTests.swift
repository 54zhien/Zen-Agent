import Foundation
import Testing
@testable import ZenAgent

@Suite("Environment Secret configuration handoff ordering")
struct EnvironmentSecretHandoffTests {
    @Test("new Secret configuration waits for an already initiated Provider handoff", .timeLimit(.minutes(1)))
    func configurationCannotOvertakeHandoff() async throws {
        let fixture = try MemoryPromptFixture.make()
        let entered = MemoryTestLatch(), release = MemoryTestLatch()
        let savingStarted = MemoryTestLatch(), saved = MemoryTestLatch()
        defer { Task { await release.open() } }
        let provider = MemoryHandoffBarrierProvider(base: fixture.provider, entered: entered, release: release)
        let runtime = ConversationRuntime(store: fixture.store, provider: provider, credentials: fixture.credentials)
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        let publicValue = "fixture-before-secret-classification"
        let runID = try await runtime.start(fixture.command(text: publicValue),
            creatingConversationIfMissing: Fixtures.conversation(id: "memory-conversation"))
        await entered.wait()
        let saving = Task {
            await savingStarted.open()
            let variable = try await environment.saveSecret(key: "AUTH", value: SecretValue(publicValue))
            await saved.open()
            return variable
        }
        await savingStarted.wait()
        for _ in 0..<100 { await Task.yield() }
        let savedDuringHandoff = await saved.opened
        #expect(!savedDuringHandoff)
        #expect(try environment.list().isEmpty)
        await release.open()
        let variable = try await saving.value
        try await runtime.waitForCompletion(runID: runID)
        #expect(try environment.list().map(\.id) == [variable.id])
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.count == 1)
        // Configuration after the handoff cannot retract an earlier public request.
        if let first = requests.first?.messages.last, case .user(let text) = first {
            #expect(text.contains(publicValue))
        } else { Issue.record("Expected the original actual Provider request") }
    }
}
