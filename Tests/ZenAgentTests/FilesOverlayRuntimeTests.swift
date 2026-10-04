import Foundation
import Testing
@testable import ZenAgent

@Suite("Files overlay Runtime retention")
@MainActor
struct FilesOverlayRuntimeTests {
    @Test("entering and closing the actual Files catalog preserves a held Runtime stream")
    func catalogNavigationDoesNotStopTheOutgoingRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let stream = Stage2StreamBox()
        let fixture = try AppShellWiringTests().makeFixture(seed: .active,
            scripts: [.holding(prefix: [.textDelta("before Files")], box: stream)], managedFiles: files)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        let shell = fixture.model
        let origin = try #require(shell.pane?.session)
        let bridge = try #require(shell.actionBridge)
        let runID = try await bridge.start(SendCommand(conversationID: origin.conversationID,
            text: "held Files run", providerInstanceID: fixture.instanceID, modelID: fixture.modelID,
            maxProviderSteps: 4, submissionID: "files-stream"))
        await stream.waitUntilReady()
        defer { stream.yieldLate(.finish(.stop)) }
        origin.composer.draft.text = "unsent Files draft"
        let navigation = WorkspaceNavigationState()
        let overlays = WorkspaceOverlayCoordinator(store: fixture.store, shell: shell, navigation: navigation)
        #expect(navigation.openSidebar(eligible: true))
        navigation.completeSettlement(try #require(navigation.settlementID))
        overlays.enter(.files, eligible: true, captureFocus: { nil })
        #expect(navigation.overlay == .files)
        let catalog = try #require(overlays.files)
        await catalog.refresh()
        #expect(catalog.items.isEmpty)
        stream.yieldLate(.textDelta(" during Files"))
        overlays.close()
        #expect(navigation.overlay == nil && shell.pane?.session === origin)
        #expect(shell.router.hasActiveRun(for: origin.conversationID))
        #expect(stream.cancellations == 0)
        stream.yieldLate(.textDelta(" after Files"))
        stream.yieldLate(.finish(.stop))
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        #expect(origin.composer.draft.text == "unsent Files draft")
        #expect(try ConversationTimelineLoader.load(conversationID: origin.conversationID, from: fixture.store)
            .turns.flatMap(\.items).contains(.assistantText("before Files during Files after Files")))
    }
}
