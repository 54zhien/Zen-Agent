import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

private actor SurfaceCommandProbe {
    var sends = 0
    var stops = 0
    let active = RunProjection(runID: "surface-active-run", state: .streaming)
    func send() -> String { sends += 1; return active.runID }
    func stop() { stops += 1 }
    func counts() -> [Int] { [sends, stops] }
}

@Suite("Stable Conversation Surface", .serialized)
@MainActor
struct ConversationSurfaceHostTests {
    @Test("a late old Surface unbind cannot steal the new Surface's Browse transport")
    func browseTransportSurvivesReversedHostUpdateOrder() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "transport-older", at: Date(timeIntervalSince1970: 1))
        try store.createEmptyConversation(id: "transport-current", at: Date(timeIntervalSince1970: 2))
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        let oldHost = ConversationSurfaceViewController(content: Text("old Pane"))
        let newHost = ConversationSurfaceViewController(content: Text("new Pane"))
        oldHost.loadViewIfNeeded()
        newHost.loadViewIfNeeded()
        oldHost.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        newHost.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        oldHost.view.layoutIfNeeded()
        newHost.view.layoutIfNeeded()
        oldHost.bindBrowse(browse)
        let lift = SurfaceLiftController()
        lift.bind(newHost)
        #expect(lift.arm(SurfaceLiftEligibility()))
        #expect(lift.drag(upwardDistance: 220, eligibility: SurfaceLiftEligibility()))
        #expect(lift.end(animated: false)?.destination == .card)
        newHost.bindBrowse(browse)
        browse.present(originID: "transport-current")
        defer { oldHost.unbindBrowse(); newHost.unbindBrowse(); lift.unbind(newHost) }

        oldHost.view.frame.size.height = 600
        oldHost.view.setNeedsLayout()
        oldHost.view.layoutIfNeeded()
        #expect(browse.viewportSize == CGSize(width: 400, height: 800))
        oldHost.unbindBrowse()
        let before = newHost.presentation
        let layout = try #require(browse.layout())
        #expect(browse.begin())
        #expect(browse.drag(displacement: 100, travel: Double(layout.travel)))
        #expect(newHost.presentation != before, "The new native Current must still render Browse updates")
        #expect(browse.selectedConversationID == "transport-current")
    }

    @Test("a retained Surface can reclaim the same Browse controller before the departing host unbinds")
    func browseTransportCanReturnToAnExistingBinding() throws {
        let browse = AppSpaceBrowseController()
        let first = ConversationSurfaceViewController(content: Text("first Pane"))
        let second = ConversationSurfaceViewController(content: Text("second Pane"))
        first.loadViewIfNeeded()
        second.loadViewIfNeeded()
        first.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        second.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        first.bindBrowse(browse)
        second.bindBrowse(browse)
        defer { first.unbindBrowse(); second.unbindBrowse() }

        // Representable updates may arrive in either order. The latest binding
        // is authoritative even when that host still retains its old transport.
        first.bindBrowse(browse)
        second.unbindBrowse()
        let returned = try #require(first.browseInteraction)
        #expect(returned.isCurrentOwner)
        returned.updateViewport()
        #expect(browse.viewportSize == CGSize(width: 320, height: 700))
        #expect(browse.onChanged != nil)
    }

    @Test("mounted Current exposes a working accessibility Delete action")
    func mountedCardAccessibilityDeleteCommitsCapturedID() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "accessible-card", at: Date())
        let browse = AppSpaceBrowseController(reader: { try store.conversationBrowseWindow(id: $0) })
        browse.configureNewEntry(reader: { try store.conversationNewBrowseWindow(originID: "accessible-card") })
        let host = ConversationSurfaceViewController(content: Text("Card"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let lift = SurfaceLiftController()
        lift.bind(host)
        host.bindBrowse(browse)
        browse.present(originID: "accessible-card")
        host.bindDeletion({ id, _ in
            guard id == "accessible-card" else { return false }
            do {
                _ = try store.beginCardDeletion(conversationID: id, at: Date())
                return true
            } catch { return false }
        }, isPending: { id in (try? store.pendingCardDeletion(id: id)) != nil })
        defer {
            host.unbindDeletion()
            host.unbindBrowse()
            lift.unbind(host)
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.layoutIfNeeded()
        #expect(lift.arm(SurfaceLiftEligibility()))
        #expect(lift.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        #expect(lift.end(animated: false)?.destination == .card)
        let action = try #require(host.surfaceView.accessibilityCustomActions?.first { $0.name == "删除会话" })
        let handler = try #require(action.actionHandler)
        #expect(handler(action))
        for _ in 0..<20 {
            if try store.conversationLifecycle(id: "accessible-card") == .pendingDeletion { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try store.conversationLifecycle(id: "accessible-card") == .pendingDeletion)
    }

    @Test(arguments: [false, true])
    func roundTripKeepsEditorOwnersDraftRunAndMessages(actualLift: Bool) async throws {
        let timeline = ConversationTimelineProjection(conversationID: "surface-conversation", turns: [
            ConversationTurn(runID: "surface-active-run", items: [.userText("committed prompt")])
        ])
        let pane = try ConversationPaneController(conversationID: timeline.conversationID,
            initialTimeline: timeline, configuration: nil,
            coalescer: StreamingCoalescer(interval: .milliseconds(0)), loadTimeline: { _ in timeline })
        pane.composer.draft = ComposerDraftState(text: "unsent draft", selection: ComposerSelection(range: 2..<5),
            references: [QuoteReference(id: "quote", source: QuoteSourceLocator(sourceConversationID: "source", sourceMessageID: "message", sourcePartID: "part", range: QuoteTextRange(utf16Start: 0, utf16Length: 6)), snapshot: "quoted", createdAt: Date(timeIntervalSince1970: 1))],
            attachments: [AttachmentReference(id: "asset", versionID: "v1", fingerprint: "sha256:test", displayName: "notes.txt", kind: .file)], presentationState: .resting)
        let probe = SurfaceCommandProbe()
        let bridge = ComposerRuntimeActionBridge(start: { _ in await probe.send() }, stop: { _ in await probe.stop() }, models: { _ in [] }, projection: { _ in await probe.active }, projectionUpdates: { _ in
            let active = await probe.active
            return AsyncStream { $0.yield(active); $0.finish() }
        })
        let host = ConversationSurfaceViewController(content: NavigationStack {
            ConversationComposerView(conversationID: pane.conversationID, controller: pane.composer, bridge: bridge, maxProviderSteps: 4)
                .navigationTitle("Surface")
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(textViews(in: host.view).first)
        let editorSelection = editor.selectedRange
        let editorCount = textViews(in: host.view).count
        let child = host.contentController
        let originalBounds = child.view.bounds
        let originalInsets = child.view.safeAreaInsets
        let composer = pane.composer
        let reading = pane.readingPosition
        _ = pane.updateReading(.userScrolled(geometry: ScrollGeometry(viewportHeight: 300, contentHeight: 1000, offset: 400), anchor: TurnAnchor(runID: "surface-active-run", relativeViewportOffset: -0.2)))
        let draft = pane.composer.draft
        let state = pane.liveStore.state
        let readingMode = reading.mode
        for progress in [CGFloat(0), 0.5, 1, 0.5, 0] {
            #expect(host.apply(.init(to: .init(scale: 0.6, translation: CGSize(width: 0.1, height: -0.2), cornerRadius: 24), progress: progress)))
            host.view.layoutIfNeeded()
            #expect(host.contentController === child)
            #expect(child.view.bounds == originalBounds)
            #expect(child.view.safeAreaInsets == originalInsets)
            #expect(pane.composer === composer)
            #expect(pane.readingPosition === reading)
            #expect(pane.composer.draft == draft)
            #expect(pane.liveStore.state == state)
            #expect(reading.mode == readingMode)
            #expect(textViews(in: host.view).first === editor)
            #expect(textViews(in: host.view).count == editorCount)
        }
        #expect(host.presentation == .full)
        if actualLift {
            let driver = SurfaceLiftController()
            driver.bind(host)
            #expect(driver.arm(SurfaceLiftEligibility()))
            #expect(driver.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
            #expect(driver.end(animated: false)?.destination == .card)
            #expect(driver.state.phase == .card)
            try await settleLayout(host)
            #expect(textViews(in: host.view).first === editor)
            #expect(textViews(in: host.view).count == editorCount)
            #expect(child.view.bounds == originalBounds)
            #expect(child.view.safeAreaInsets == originalInsets)
            #expect(editor.selectedRange == editorSelection)
            #expect(pane.composer.draft == draft && pane.liveStore.state == state)
            #expect(reading.mode == readingMode)
            #expect(driver.returnToFull(animated: false))
            try await settleLayout(host)
            #expect(host.contentController === child && pane.composer === composer)
            #expect(pane.readingPosition === reading)
            #expect(textViews(in: host.view).first === editor)
            #expect(textViews(in: host.view).count == editorCount)
            #expect(child.view.safeAreaInsets == originalInsets)
            #expect(editor.selectedRange == editorSelection)
            #expect(pane.composer.draft == draft && pane.liveStore.state == state)
            #expect(reading.mode == readingMode)
        }
        #expect(await probe.counts() == [0, 0])
        #expect(await probe.active.runID == "surface-active-run")
    }

    @Test func presentationChangesPixelsWithoutRelayoutAndInvalidUpdateKeepsLastState() throws {
        let host = ConversationSurfaceViewController(content: Text("content"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let bounds = host.contentController.view.bounds
        let request = SurfaceGeometry.Request(to: .init(scale: 0.6, translation: .zero, cornerRadius: 24), progress: 1)
        #expect(host.apply(request))
        #expect(host.surfaceView.transform.a == 0.6)
        #expect(host.surfaceView.layer.cornerRadius == 24)
        #expect(host.contentController.view.bounds == bounds)
        let presentation = host.presentation
        #expect(!host.apply(.init(to: request.to, progress: .nan)))
        #expect(host.presentation == presentation)
        #expect(host.surfaceView.transform.a == 0.6)
        #expect(host.apply(.full))
        #expect(host.surfaceView.transform == .identity)
        #expect(host.surfaceView.layer.cornerRadius == 0)
    }

    @Test func teardownReleasesHostAndContent() {
        weak var weakHost: UIViewController?
        weak var weakContent: UIViewController?
        autoreleasepool {
            let host = ConversationSurfaceViewController(content: Text("released"))
            host.loadViewIfNeeded()
            weakHost = host
            weakContent = host.contentController
        }
        #expect(weakHost == nil)
        #expect(weakContent == nil)
    }

    @Test func viewportResizeRecomputesTranslationWithoutReplacingContent() {
        let host = ConversationSurfaceViewController(content: Text("resized"))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        host.view.layoutIfNeeded()
        let child = host.contentController
        #expect(host.apply(.init(to: .init(scale: 0.6, translation: CGSize(width: 0.1, height: -0.2), cornerRadius: 24), progress: 1)))
        #expect(host.presentation.translation == CGSize(width: 40, height: -160))
        host.view.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(host.contentController === child)
        #expect(host.presentation.translation == CGSize(width: 20, height: -60))
        #expect(host.contentController.view.bounds.size == CGSize(width: 200, height: 300))
        #expect(host.apply(.full))
        #expect(host.surfaceView.transform == .identity)
    }

    @Test func containerSafeAreaChangesWhileScaledConverge() async throws {
        let host = ConversationSurfaceViewController(content: Text("safe area"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        for insets in [UIEdgeInsets(top: 21, left: 9, bottom: 13, right: 7), .zero] {
            #expect(host.apply(.init(to: .init(scale: 0.6, translation: CGSize(width: 0.1, height: -0.2), cornerRadius: 24), progress: 1)))
            try await settleLayout(host)
            host.additionalSafeAreaInsets = insets
            try await settleLayout(host)
            for progress in [CGFloat(0.5), 1, 0.5, 0] {
                #expect(host.apply(.init(to: .init(scale: 0.6, translation: CGSize(width: 0.1, height: -0.2), cornerRadius: 24), progress: progress)))
                try await settleLayout(host)
                #expect(host.contentController.view.safeAreaInsets == host.view.safeAreaInsets)
                let settled = host.contentController.additionalSafeAreaInsets
                for _ in 0..<3 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    #expect(host.contentController.additionalSafeAreaInsets == settled)
                    #expect(host.contentController.view.safeAreaInsets == host.view.safeAreaInsets)
                }
            }
        }
    }

    private func settleLayout(_ host: UIViewController) async throws {
        // UIKit propagates changed ancestor insets through subsequent layout passes.
        // The convergence contract is checked after that propagation, then challenged
        // with extra layouts whose compensation values must remain unchanged.
        for _ in 0..<3 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
