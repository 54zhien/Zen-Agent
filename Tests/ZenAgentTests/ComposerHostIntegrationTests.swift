import Testing
import UIKit

@testable import ZenAgent

@MainActor
@Suite("Composer host wiring")
struct ComposerHostIntegrationTests {
    @Test("editorIdentitySurvivesMorphAndPlaceholderSharesOrigin")
    func editorIdentitySurvivesMorph() {
        let (window, host) = installedHost()
        _ = window
        let editor = host.editor
        host.configure(configuration(state: .resting))
        host.layoutIfNeeded()
        #expect(abs(host.keyboardGap - 12) < 1)
        #expect(host.editor === editor)
        #expect(host.placeholder.superview === editor.superview)
        #expect(host.placeholder.frame.origin == editor.frame.origin)
        host.configure(configuration(state: .editing))
        host.configure(configuration(state: .resting))
        #expect(host.editor === editor)
    }

    @Test("primary action binds to latest callback exactly once")
    func primaryCallbackUsesLatestConfiguration() {
        let (window, host) = installedHost()
        _ = window
        var oldCount = 0
        var newCount = 0
        host.configure(configuration(onSend: { oldCount += 1 }))
        host.configure(configuration(onSend: { newCount += 1 }))
        let button = findButton(in: host, id: "conversation-composer-send")
        #expect(button != nil)
        button?.sendActions(for: .touchUpInside)
        #expect(oldCount == 0)
        #expect(newCount == 1)
    }

    private func installedHost() -> (UIWindow, ComposerHostView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let host = ComposerHostView(frame: controller.view.bounds)
        controller.view.addSubview(host)
        host.configure(configuration())
        host.layoutIfNeeded()
        return (window, host)
    }

    private func configuration(
        state: ComposerPresentationState = .resting,
        onSend: @escaping () -> Void = {}
    ) -> ComposerHostView.Configuration {
        ComposerHostView.Configuration(
            text: "hello", selection: ComposerSelection(range: 0..<0),
            state: state, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false,
            primary: .send(enabled: true), models: [], selectedModelID: "",
            errorMessage: nil,
            onText: { _, _, _ in }, onFocus: { _ in }, onSend: onSend,
            onStop: {}, onModel: { _ in }
        )
    }

    private func findButton(in view: UIView, id: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        for child in view.subviews {
            if let button = findButton(in: child, id: id) { return button }
        }
        return nil
    }
}
