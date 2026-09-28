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
    @Test func roundTripKeepsEditorOwnersDraftRunAndMessages() async throws {
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
        let editorCount = textViews(in: host.view).count
        let child = host.contentController
        let originalBounds = child.view.bounds
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
            #expect(pane.composer === composer)
            #expect(pane.readingPosition === reading)
            #expect(pane.composer.draft == draft)
            #expect(pane.liveStore.state == state)
            #expect(reading.mode == readingMode)
            #expect(textViews(in: host.view).first === editor)
            #expect(textViews(in: host.view).count == editorCount)
        }
        #expect(host.presentation == .full)
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

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
