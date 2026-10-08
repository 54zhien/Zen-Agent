import Testing
import UIKit
@testable import ZenAgent

@Suite("Shared Composer native lifecycle", .serialized)
@MainActor
struct WorkspaceComposerDockTests {
    @Test func parkedEditorReceivesKeyboardDismissalFromItsWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
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
        let trace = ComposerDockFocusTrace(window: window, variant: preserveOutgoing)
        defer {
            trace.record("before-cleanup")
            trace.finish()
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
        trace.outgoing = a.composer.editor; trace.incoming = b.composer.editor
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)
        func update(_ portal: ComposerHostPortal, id: String, editing: Bool, active: Bool = true) {
            trace.record("update-begin owner=\(id) requested=\(editing) active=\(active)")
            portal.update(configuration: configuration(text: id, editing: editing, onFocus: { value in
                trace.record("delegate owner=\(id) focused=\(value)")
            }), focused: editing,
                suppressed: false, ownerID: id, usesDock: true, dock: dock, isActivePane: active)
            trace.record("update-end owner=\(id)")
        }
        update(a, id: "a", editing: true); update(b, id: "b", editing: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(a.composer.editor.isFirstResponder)
        update(a, id: "a", editing: false, active: !preserveOutgoing)
        if preserveOutgoing { #expect(a.composer.editor.isFirstResponder) }
        update(b, id: "b", editing: true)
        dock.configure(container: container, activeID: "b", visible: true)
        trace.record("incoming-installed")
        #expect(b.composer.editor.isFirstResponder, "incoming editor must receive focus at attachment")
        try await Task.sleep(for: .milliseconds(250))
        trace.record("settled-check")
        #expect(b.composer.editor.isFirstResponder, "settled focus; keyWindow=\(window.isKeyWindow), attached=\(b.composer.window === window)")
        #expect(!a.composer.editor.isFirstResponder)
        #expect(b.composer.editor.text == "b" && a.composer.editor.text == "a")
    }

    @Test("bounded repeated outgoing-first focus handoff", arguments: Array(0..<5))
    func repeatedOutgoingFirstHandoffRetainsSettledFocus(attempt: Int) async throws {
        print("S5_DOCK_ATTEMPT \(attempt)")
        try await focusIntentSurvivesOutgoingThenIncomingThenDockUpdateOrder(preserveOutgoing: false)
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
private final class ComposerDockFocusTrace: NSObject {
    weak var outgoing: UITextView?
    weak var incoming: UITextView?
    private weak var window: UIWindow?
    private let variant: Bool
    private let start = ProcessInfo.processInfo.systemUptime
    private var events: [String] = []

    init(window: UIWindow, variant: Bool) {
        self.window = window; self.variant = variant
        super.init()
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                     UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: name, object: nil)
        }
        record("trace-start")
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func record(_ event: String) {
        guard events.count < 64 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        events.append("t=\(elapsed) \(event) key=\(window?.isKeyWindow == true) aFocused=\(outgoing?.isFirstResponder == true) bFocused=\(incoming?.isFirstResponder == true) bAttached=\(incoming?.window === window)")
    }
    @objc private func receive(_ notification: Notification) {
        let object = notification.object as AnyObject?
        let owner = object == nil ? "nil" : object === outgoing ? "a" : object === incoming ? "b" : "foreign"
        let identity = object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        record("notification=\(notification.name.rawValue) owner=\(owner) object=\(identity)")
        if notification.name == UITextView.textDidEndEditingNotification, object === incoming {
            record("b-end-stack=\(Thread.callStackSymbols.prefix(18).joined(separator: " <- "))")
        }
    }
    func finish() {
        NotificationCenter.default.removeObserver(self)
        let identity = window.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        for (index, event) in events.enumerated() {
            print("S5_DOCK_FOCUS variant=\(variant) window=\(identity) seq=\(index) \(event)")
        }
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
