import Foundation
import Testing
@testable import ZenAgent

@MainActor
private final class ShellLifetimeProbe {
    weak var shell: AppShellModel?
    weak var router: RunEventRouter?
    weak var pane: ConversationPaneController?
    weak var runtime: ConversationRuntime?
    weak var database: ZenDatabase?

    func observe(_ fixture: ShellFixture) {
        shell = fixture.model
        router = fixture.model.router
        pane = fixture.model.pane
        runtime = fixture.runtime
        database = fixture.store.database
    }
}

@Suite("App shell presentation lifetime", .serialized)
@MainActor
struct AppShellLifetimeTests {
    @Test("discarding a shell releases its database even after a Send coordinator was cached",
          arguments: ["idle", "coordinator", "completedSend"])
    func releasedShellHasNoOwnershipCycle(stage: String) async throws {
        let probe = ShellLifetimeProbe()
        try await exerciseShell(stage: stage, probe: probe)
        #expect(probe.shell == nil)
        #expect(probe.router == nil)
        #expect(probe.pane == nil)
        #expect(probe.runtime == nil)
        #expect(probe.database == nil)
    }

    private func exerciseShell(stage: String, probe: ShellLifetimeProbe) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active,
            scripts: [.events([.textDelta("reply"), .finish(.stop)])])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        probe.observe(fixture)
        let pane = try #require(fixture.model.pane)
        if stage != "idle" {
            let bridge = try #require(fixture.model.actionBridge)
            let coordinator = pane.session.sendCoordinator(bridge: bridge, maxProviderSteps: 4)
            if stage == "completedSend" {
                pane.composer.draft.text = "lifetime regression"
                _ = await coordinator.handlePrimaryAction()
                let run = try #require(try fixture.store.runs(inConversation: pane.conversationID).first)
                try await fixture.runtime.waitForCompletion(runID: run.id)
                #expect(try fixture.store.run(id: run.id)?.state == .completed)
            }
        }
    }

    @Test("an active Runtime persists its completion after the shell and Pane are released")
    func activeRuntimeDoesNotRetainPresentation() async throws {
        let probe = ShellLifetimeProbe()
        let stream = Stage2StreamBox()
        let (runtime, store, runID) = try await startHoldingRun(probe: probe, stream: stream)
        #expect(probe.shell == nil)
        #expect(probe.router == nil)
        #expect(probe.pane == nil)
        #expect(try store.run(id: runID)?.state.isActive == true)
        stream.yieldLate(.textDelta("after shell release"))
        stream.yieldLate(.finish(.stop))
        try await runtime.waitForCompletion(runID: runID)
        #expect(try store.run(id: runID)?.state == .completed)
        let run = try #require(try store.run(id: runID))
        let messages = try store.messages(inConversation: run.conversationID)
        let text: String = try messages.flatMap { try store.parts(ofMessage: $0.id) }
            .filter { $0.kind == .text }
            .compactMap { try store.text(ofPart: $0.id) }.joined()
        #expect(text.contains("after shell release"))
    }

    private func startHoldingRun(probe: ShellLifetimeProbe, stream: Stage2StreamBox) async throws
        -> (ConversationRuntime, PersistenceStore, String) {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active,
            scripts: [.holding(prefix: [], box: stream)])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        probe.observe(fixture)
        let pane = try #require(fixture.model.pane)
        pane.composer.draft.text = "active lifetime regression"
        let bridge = try #require(fixture.model.actionBridge)
        _ = await pane.session.sendCoordinator(bridge: bridge, maxProviderSteps: 4).handlePrimaryAction()
        let run = try #require(try fixture.store.runs(inConversation: pane.conversationID).first)
        await stream.waitUntilReady()
        return (fixture.runtime, fixture.store, run.id)
    }
}
