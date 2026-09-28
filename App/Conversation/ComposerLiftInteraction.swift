import UIKit

/// Gesture/readiness transport only. Draft, selection and Run ownership stay with
/// the existing Composer; an unsafe gesture is refused rather than replayed later.
@MainActor
final class ComposerLiftInteraction: NSObject, UIGestureRecognizerDelegate {
    struct Configuration {
        let driver: SurfaceLiftController
        let eligibility: (SurfaceLiftEligibility) -> SurfaceLiftEligibility
    }

    private weak var surface: UIView?
    private weak var editor: UITextView?
    private let nativeInput: () -> SurfaceLiftEligibility
    private var configuration: Configuration?
    private var origin: CGPoint?
    private(set) var keyboardTransitioning = false
    private(set) var keyboardVisible = false
    let recognizer = UILongPressGestureRecognizer()

    init(surface: UIView, editor: UITextView, nativeInput: @escaping () -> SurfaceLiftEligibility) {
        self.surface = surface
        self.editor = editor
        self.nativeInput = nativeInput
        super.init()
        recognizer.addTarget(self, action: #selector(gestureChanged(_:)))
        recognizer.delegate = self
        recognizer.isEnabled = false
        surface.addGestureRecognizer(recognizer)
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                   name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(_ configuration: Configuration?) {
        if self.configuration?.driver !== configuration?.driver {
            self.configuration?.driver.invalidate()
            origin = nil
        }
        self.configuration = configuration
        recognizer.isEnabled = configuration != nil
        checkReadiness()
    }

    var isInstalled: Bool { configuration != nil }

    private var input: SurfaceLiftEligibility {
        configuration?.eligibility(nativeInput()) ?? nativeInput()
    }

    func checkReadiness() {
        if !input.allowsLift {
            let driver = configuration?.driver
            let returning = driver?.state.phase == .settling
                && driver?.state.pendingSettlement?.destination == .full
            // A freshly remounted editor must finish layout before it can start
            // another Lift. That readiness does not cancel an existing Return.
            if !returning { driver?.invalidate(); origin = nil }
        }
        editor?.accessibilityCustomActions = configuration != nil
            ? [UIAccessibilityCustomAction(name: "提起会话", target: self,
                                           selector: #selector(liftForAccessibility))] : nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        configuration?.driver.canArm(input) == true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === surface
    }

    @objc private func gestureChanged(_ gesture: UILongPressGestureRecognizer) {
        guard let configuration, let window = surface?.window else { return }
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
            origin = configuration.driver.arm(input) ? point : nil
        case .changed:
            guard let origin else { return }
            if !configuration.driver.drag(upwardDistance: Double(origin.y - point.y), eligibility: input) {
                self.origin = nil
            }
        case .ended, .cancelled, .failed:
            defer { origin = nil }
            guard origin != nil else { return }
            guard input.allowsLift else { configuration.driver.invalidate(); return }
            _ = configuration.driver.end(cancelled: gesture.state != .ended)
        default:
            break
        }
    }

    @objc private func liftForAccessibility() -> Bool {
        guard let configuration, configuration.driver.arm(input) else { return false }
        guard configuration.driver.drag(upwardDistance: 180, eligibility: input) else { return false }
        _ = configuration.driver.end()
        return true
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let window = surface?.window else { return }
        if let screen = notification.object as? UIScreen, screen !== window.screen { return }
        if notification.name == UIResponder.keyboardWillChangeFrameNotification {
            keyboardTransitioning = true
        } else {
            keyboardTransitioning = false
        }
        if notification.name == UIResponder.keyboardDidHideNotification {
            keyboardVisible = false
        } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let local = window.convert(frame, from: window.screen.coordinateSpace)
            let intersection = window.bounds.intersection(local)
            keyboardVisible = !intersection.isNull && intersection.height > window.safeAreaInsets.bottom + 1
        }
        checkReadiness()
    }
}
