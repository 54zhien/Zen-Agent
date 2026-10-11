import Testing
import UIKit
@testable import ZenAgent

@Suite("Shared Composer native lifecycle", .serialized)
@MainActor
struct WorkspaceComposerDockTests {
    @Test func parkedEditorReceivesKeyboardDismissalFromItsWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // This observes screen-scoped notifications, not native focus. Keep the
        // fixture attached to a Window without starting a scene/key transition.
        let window = UIWindow(windowScene: scene)
        let surface = UIView(frame: window.bounds)
        let editor = UITextView()
        window.addSubview(surface); surface.addSubview(editor)
        let interaction = ComposerLiftInteraction(surface: surface, editor: editor) { SurfaceLiftEligibility() }
        let visible = window.convert(CGRect(x: 0, y: window.bounds.height - 300,
            width: window.bounds.width, height: 300), to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.screen,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visible])
        #expect(interaction.keyboardVisible)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: window.screen,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visible])
        #expect(interaction.keyboardTransitioning)
        surface.removeFromSuperview()
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: window.screen)
        window.addSubview(surface)
        #expect(!interaction.keyboardVisible)
        #expect(!interaction.keyboardTransitioning)
    }

    @Test(arguments: [false, true])
    func focusIntentSurvivesOutgoingThenIncomingThenDockUpdateOrder(preserveOutgoing: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        // A newly keyed Window can still be completing its root appearance.
        // Drive focus only after UIKit has finished that initial transition.
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        let loss = NativeFocusLossEvidence()
        let observer = NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification,
            object: b.composer.editor, queue: .main) { _ in
                MainActor.assumeIsolated { loss.capture(scene: scene, window: window) }
            }
        defer { loss.armed = false; NotificationCenter.default.removeObserver(observer) }
        dock.configure(container: container, activeID: "a", visible: true)
        func update(_ portal: ComposerHostPortal, id: String, editing: Bool, active: Bool = true) {
            portal.update(configuration: configuration(text: id, editing: editing), focusRequested: { editing },
                suppressed: false, ownerID: id, usesDock: true, dock: dock, isActivePane: active)
        }
        update(a, id: "a", editing: true); update(b, id: "b", editing: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(a.composer.editor.isFirstResponder)
        update(a, id: "a", editing: false, active: !preserveOutgoing)
        if preserveOutgoing { #expect(a.composer.editor.isFirstResponder) }
        update(b, id: "b", editing: true)
        dock.configure(container: container, activeID: "b", visible: true)
        #expect(b.composer.editor.isFirstResponder, "incoming editor must receive focus at attachment")
        loss.arm()
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder, "settled focus; keyWindow=\(window.isKeyWindow), attached=\(b.composer.window === window); loss=\(loss.receipt)")
        #expect(!a.composer.editor.isFirstResponder)
        #expect(b.composer.editor.text == "b" && a.composer.editor.text == "a")
    }

    @Test("Dock refresh cannot replay a stale blur between native transfer and bridge feedback", arguments: [false, true])
    func refreshBeforeBridgeFeedbackKeepsTransferredFocus(refreshBeforeFeedback: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)

        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        let outgoing = ComposerController(configuration: nil), incoming = ComposerController(configuration: nil)
        outgoing.draft.text = "a"; incoming.draft.text = "b"
        _ = outgoing.handle(.textAreaTapped)
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)

        func update(_ portal: ComposerHostPortal, id: String, controller: ComposerController, active: Bool) {
            let editing = controller.draft.presentationState == .editing
            portal.update(configuration: configuration(text: id, editing: editing, onFocus: { focused in
                let event: ComposerPresentationEvent = focused ? .textAreaTapped : .keyboardDismissed
                _ = controller.handle(event)
            }), focusRequested: { controller.draft.presentationState == .editing }, suppressed: false, ownerID: id, usesDock: true,
                dock: dock, isActivePane: active)
        }
        update(a, id: "a", controller: outgoing, active: true)
        update(b, id: "b", controller: incoming, active: false)
        try await Task.sleep(for: .milliseconds(250))
        try #require(a.composer.editor.isFirstResponder)

        // The incoming bridge can receive the active-Pane environment before
        // the Dock's activeID update, while its draft is still resting.
        update(b, id: "b", controller: incoming, active: true)
        // Native transfer publishes .editing synchronously; SwiftUI delivers
        // that state to the portal on a later update. Refresh the same Dock in
        // that gap, without issuing a new input/blur intent from either owner.
        dock.configure(container: container, activeID: "b", visible: true)
        try #require(b.composer.editor.isFirstResponder)
        #expect(incoming.draft.presentationState == .editing)
        if refreshBeforeFeedback {
            dock.configure(container: container, activeID: "b", visible: true)
            #expect(b.composer.editor.isFirstResponder, "an unchanged Dock refresh must not replay the old resting focus request")
            #expect(incoming.draft.presentationState == .editing)
        }
        update(b, id: "b", controller: incoming, active: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder)
        #expect(!a.composer.editor.isFirstResponder)
        #expect(incoming.draft.presentationState == .editing)
        #expect(a.composer.editor.text == "a" && b.composer.editor.text == "b")

        // Explicit bridge blur must still release focus after handoff.
        _ = incoming.handle(.keyboardDismissed)
        update(b, id: "b", controller: incoming, active: true)
        #expect(!b.composer.editor.isFirstResponder)
    }

    @Test("a bridge snapshot cannot undo newer native focus; a new explicit blur still applies", arguments: [false, true])
    func bridgeSnapshotAfterNativeTransfer(explicitBlur: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        let incoming = ComposerController(configuration: nil)
        incoming.draft.text = "incoming draft"
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)
        a.update(configuration: configuration(text: "outgoing draft", editing: true), focusRequested: { true },
            suppressed: false, ownerID: "a", usesDock: true, dock: dock)
        // SwiftUI can evaluate a value before UIKit transfers the responder.
        // Keep that value while the real delegate publishes the newer intent.
        let pendingConfiguration = configuration(text: incoming.draft.text, editing: false, onFocus: { focused in
            _ = incoming.handle(focused ? .textAreaTapped : .keyboardDismissed)
        })
        let pendingFocus = { incoming.draft.presentationState == .editing }
        b.update(configuration: pendingConfiguration, focusRequested: pendingFocus, suppressed: false,
            ownerID: "b", usesDock: true, dock: dock)
        try await Task.sleep(for: .milliseconds(250))
        try #require(a.composer.editor.isFirstResponder)
        dock.configure(container: container, activeID: "b", visible: true)
        try #require(b.composer.editor.isFirstResponder)
        try #require(incoming.draft.presentationState == .editing)
        // There has not yet been a bridge update containing focused=true.
        if explicitBlur { _ = incoming.handle(.conversationBackgroundTapped) }
        b.update(configuration: pendingConfiguration, focusRequested: pendingFocus, suppressed: false,
            ownerID: "b", usesDock: true, dock: dock)
        #expect(b.composer.editor.isFirstResponder == !explicitBlur,
                "a stale resting render must not issue a new keyboard-dismissal intent")
        #expect((incoming.draft.presentationState == .editing) == !explicitBlur)
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder == !explicitBlur)
        #expect(!a.composer.editor.isFirstResponder)
        #expect(b.composer.editor.text == "incoming draft" && a.composer.editor.text == "outgoing draft")
    }

    @Test("a focus request made before Dock window attachment is retried after attachment")
    func windowAttachmentRetriesPendingFocusWithoutReplayingBlur() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)

        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let portal = ComposerHostPortal(frame: root.view.bounds)
        dock.configure(container: container, activeID: "pending", visible: true)
        portal.update(configuration: configuration(text: "retained", editing: true), focusRequested: { true },
            suppressed: false, ownerID: "pending", usesDock: true, dock: dock)
        try #require(portal.composer.superview === container && portal.composer.window == nil)
        #expect(!portal.composer.editor.isFirstResponder)

        root.view.addSubview(container)
        try #require(portal.composer.window === window)
        dock.configure(container: container, activeID: "pending", visible: true)
        #expect(portal.composer.editor.isFirstResponder, "a previously unattached positive request must still be applied")
        try await Task.sleep(for: .milliseconds(250))
        #expect(portal.composer.editor.isFirstResponder)
        #expect(portal.composer.editor.text == "retained")

        portal.update(configuration: configuration(text: "retained", editing: false), focusRequested: { false },
            suppressed: false, ownerID: "pending", usesDock: true, dock: dock)
        #expect(!portal.composer.editor.isFirstResponder)
        dock.configure(container: container, activeID: "pending", visible: true)
        #expect(!portal.composer.editor.isFirstResponder)
    }

    @Test("notification-only fixture must not take key ownership from an editing window")
    func notificationFixturePreservesEditingWindow() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let editor = UITextView(frame: root.view.bounds)
        root.view.addSubview(editor)
        editor.text = "retained"
        try #require(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(250))
        try #require(editor.isFirstResponder)
        let changes = DockWindowKeyChanges()
        let observer = NotificationCenter.default.addObserver(forName: UIWindow.didResignKeyNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { changes.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        try parkedEditorReceivesKeyboardDismissalFromItsWindow()
        #expect(changes.count == 0, "a synthetic notification fixture must not replace the active editor's key window")
        #expect(window.isKeyWindow && editor.isFirstResponder)
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.isKeyWindow && editor.isFirstResponder)
        #expect(editor.text == "retained")
    }

    private func configuration(text: String, editing: Bool,
                               onFocus: @escaping (Bool) -> Void = { _ in }) -> ComposerHostView.Configuration {
        .init(text: text, selection: ComposerSelection(range: 0..<0),
            state: editing ? .editing : .resting, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false, primary: .send(enabled: true),
            models: [], selectedModelID: nil, errorMessage: nil, references: [],
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: onFocus, onSend: {}, onStop: {},
            onModel: { _ in }, onHeightChanged: { _ in })
    }
}

/// Observe only the unexpected loss, after it happens. No focus request, timer,
/// warmup or logging is added to the native transfer being checked.
@MainActor
final class NativeFocusLossEvidence {
    var armed = false
    private(set) var receipt = "no end-editing notification"
    private var expectedText: String?

    func arm(expectedText: String? = nil) {
        self.expectedText = expectedText
        receipt = "no end-editing notification"
        armed = true
    }

    func capture(scene: UIWindowScene, window: UIWindow, editor: UITextView? = nil) {
        guard armed, expectedText == nil || editor?.text == expectedText else { return }
        armed = false
        func responders(in view: UIView) -> [String] {
            (view.isFirstResponder ? ["\(type(of: view)):\(ObjectIdentifier(view))"] : [])
                + view.subviews.flatMap { responders(in: $0) }
        }
        let windows: String = scene.windows.map {
            "\(ObjectIdentifier($0)):key=\($0.isKeyWindow):hidden=\($0.isHidden):responders=\(responders(in: $0))"
        }.joined(separator: " | ")
        let stack: String = Thread.callStackSymbols.prefix(24).joined(separator: " | ")
        receipt = "time=\(ProcessInfo.processInfo.systemUptime);scene=\(scene.activationState.rawValue);key=\(window.isKeyWindow);windows=[\(windows)];stack=\(stack)"
    }
}

@MainActor
private final class ComposerDockTestRoot: UIViewController {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
    }
}

@MainActor private final class DockWindowKeyChanges { var count = 0 }
