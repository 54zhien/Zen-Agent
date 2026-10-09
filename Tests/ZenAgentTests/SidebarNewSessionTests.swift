import SwiftUI
import Testing
import UIKit
@testable import ZenAgent

@Suite("Sidebar New session ownership")
@MainActor
struct SidebarNewSessionTests {
    @Test("Sidebar New retains the unsent owner for App Space Return")
    func sidebarNewRetainsUnsentSessionAndRestoresDraft() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let shell = fixture.model
        await shell.launchRestorationTask?.value
        let original = try #require(shell.pane?.session)
        let originalID = shell.conversationID
        original.composer.draft.text = "未发送的草稿 🧑🏽‍💻"
        original.composer.draft.selection = ComposerSelection(range: 1..<3)
        original.composer.draft.references = [QuoteReference(id: "sidebar-quote",
            source: QuoteSourceLocator(sourceConversationID: "source", sourceMessageID: "message",
                sourcePartID: "part", range: QuoteTextRange(utf16Start: 0, utf16Length: 4)),
            snapshot: "text", createdAt: Fixtures.epoch)]
        original.composer.draft.attachments = [AttachmentReference(id: "sidebar-asset",
            versionID: "version", fingerprint: "hash", displayName: "file", kind: .file)]
        let navigation = WorkspaceNavigationState()
        let host = UIHostingController(rootView: NewConversationView(model: shell)
            .environment(\.workspaceNavigation, navigation))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        // Mount onAppear's navigation callbacks without acquiring global keyboard focus.
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #expect(!window.isKeyWindow)
        for _ in 0..<100 where navigation.onConversationAction == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let action = try #require(navigation.onConversationAction)
        let draft = original.composer.draft
        let configuration = original.composer.configuration
        action(.new)
        #expect(shell.conversationID != originalID)
        #expect(shell.enterPreview())
        #expect(try shell.newConversationBrowseWindow().summaries.contains { $0.id == originalID })
        let ready = await shell.preparePreviewReturn(to: originalID)
        #expect(ready)
        guard ready else { return }
        #expect(shell.commitPreviewReturn())
        #expect(shell.conversationID == originalID)
        #expect(shell.pane?.session === original)
        #expect(shell.pane?.composer.draft == draft)
        #expect(shell.pane?.composer.configuration == configuration)
        #expect(try fixture.store.conversationLifecycle(id: originalID) == nil)
        #expect(try fixture.store.activeParentRunIDs().isEmpty)
    }

    @Test("Sidebar New retires only a reconstructible blank owner",
          arguments: ["blank", "configuration", "reading", "pending"])
    func sidebarNewRetiresOnlyReconstructibleBlankSession(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let shell = fixture.model
        await shell.launchRestorationTask?.value
        let original = try #require(shell.pane?.session)
        switch kind {
        case "configuration":
            original.composer.configuration = nil
        case "reading":
            _ = original.readingPosition.apply(.userScrolled(
                geometry: ScrollGeometry(viewportHeight: 100, contentHeight: 500, offset: 0),
                anchor: TurnAnchor(runID: "turn", relativeViewportOffset: 0)))
        case "pending":
            original.composer.draft.text = "pending"
            let bridge = try #require(shell.actionBridge)
            let coordinator = original.sendCoordinator(bridge: bridge, maxProviderSteps: 4)
            #expect(coordinator.beginSend(capabilities: [.text, .streaming], quoteCommitReady: true,
                imageInputReady: false, fileInputReady: false, submissionID: "sidebar-pending") != nil)
            original.composer.draft.text = ""
        default: break
        }
        shell.newConversation()
        #expect(shell.enterPreview())
        let window = try shell.newConversationBrowseWindow()
        #expect(window.summaries.contains { $0.id == original.conversationID } == (kind != "blank"))
    }

    @Test("uncommitted replacement cannot retire a runtime-protected owner")
    func runtimeProtectionPreventsBlankRetirement() {
        let sessions = ConversationSessionStore()
        let original = ConversationSession(conversationID: "protected", configuration: nil)
        sessions.retain(original, reconstruction: .uncommitted)
        sessions.activate(original)
        sessions.activate(ConversationSession(conversationID: "replacement", configuration: nil),
            isRuntimeProtected: { $0 == original.conversationID })
        #expect(sessions.session(for: original.conversationID) === original)
    }
}
