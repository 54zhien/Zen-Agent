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

    private func configuration(text: String, editing: Bool) -> ComposerHostView.Configuration {
        .init(text: text, selection: ComposerSelection(range: 0..<0),
            state: editing ? .editing : .resting, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false, primary: .send(enabled: true),
            models: [], selectedModelID: nil, errorMessage: nil, references: [],
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: { _ in }, onSend: {}, onStop: {},
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
