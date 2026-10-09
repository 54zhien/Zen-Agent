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
        var focusEvents: [String] = []
        var samplingStarted = false
        ComposerHostView.focusDiagnostic = { host, event in
            guard host === a.composer || host === b.composer else { return }
            let owner = host === a.composer ? "a" : "b"
            focusEvents.append("FOCUS_CALL \(Date().timeIntervalSince1970) preserve=\(preserveOutgoing) owner=\(owner) event=\(event) responder=\(host.editor.isFirstResponder)")
            if !preserveOutgoing, !samplingStarted, owner == "a", event == "requestFocus(false) enter" {
                samplingStarted = true
                // The native log stream delivered the previous marker seconds late.
                // Publish atomically before resignation without waiting for the sampler.
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("s5-focus-resign.json")
                do {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "requestedAt": Date().timeIntervalSince1970,
                        "event": event
                    ])
                    try data.write(to: marker, options: .atomic)
                } catch {
                    focusEvents.append("FOCUS_CAPTURE_WRITE_FAILED \(error)")
                }
            }
        }
        defer {
            ComposerHostView.focusDiagnostic = nil
            print(focusEvents.joined(separator: "\n"))
        }
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)
        func update(_ portal: ComposerHostPortal, id: String, editing: Bool, active: Bool = true) {
            portal.update(configuration: configuration(text: id, editing: editing), focused: editing,
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
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder, "settled focus; keyWindow=\(window.isKeyWindow), attached=\(b.composer.window === window)")
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
            }), focused: editing, suppressed: false, ownerID: id, usesDock: true,
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
        portal.update(configuration: configuration(text: "retained", editing: true), focused: true,
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

        portal.update(configuration: configuration(text: "retained", editing: false), focused: false,
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

@MainActor
private final class ComposerDockTestRoot: UIViewController {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
    }
}

@MainActor private final class DockWindowKeyChanges { var count = 0 }
