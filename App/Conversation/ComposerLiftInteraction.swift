import UIKit

/// Gesture/readiness transport only. Draft, selection and Run ownership stay with
/// the existing Composer; an unsafe gesture is refused rather than replayed later.
@MainActor
final class ComposerLiftInteraction: NSObject, UIGestureRecognizerDelegate {
    struct Configuration {
        let driver: SurfaceLiftController
        let conversationID: String
        let eligibility: (SurfaceLiftEligibility) -> SurfaceLiftEligibility
    }

    private weak var surface: UIView?
    private weak var editor: UITextView?
    private weak var keyboardWindow: UIWindow?
    private let nativeInput: () -> SurfaceLiftEligibility
    private let feedback: ComposerLiftFeedback
    private var configuration: Configuration?
    private var origin: CGPoint?
    private(set) var keyboardTransitioning = false
    private(set) var keyboardVisible = false
    let recognizer = UILongPressGestureRecognizer()
#if DEBUG
    private let recordsUITestGestures = ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1"
    private var gestureTrace: [String] = []
    private weak var diagnosticDriver: SurfaceLiftController?
    private weak var observedTouch: UITouch?
    private var recordedFirstChange = false
#endif

    init(surface: UIView, editor: UITextView, nativeInput: @escaping () -> SurfaceLiftEligibility) {
        self.surface = surface
        self.editor = editor
        self.nativeInput = nativeInput
        feedback = ComposerLiftFeedback(surface: surface)
        super.init()
        recognizer.addTarget(self, action: #selector(gestureChanged(_:)))
        recognizer.delegate = self
        // Keep the editor as the actual hit target. A successful Lift consumes
        // its initial touch; a short tap is delivered after Lift fails.
        recognizer.delaysTouchesBegan = true
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
#if DEBUG
        let tracingRefresh = recognizer.state == .began || recognizer.state == .changed
        if tracingRefresh { recordGesture("configureBefore;enabled=\(recognizer.isEnabled);nextInstalled=\(configuration != nil)") }
#endif
        if self.configuration?.driver !== configuration?.driver {
            feedback.setReady(false)
            self.configuration?.driver.invalidate()
            origin = nil
        }
        self.configuration = configuration
        recognizer.isEnabled = configuration != nil
#if DEBUG
        if tracingRefresh { recordGesture("configureAfter;gesture=\(recognizer.state.rawValue);enabled=\(recognizer.isEnabled)") }
#endif
        checkReadiness()
    }

    var isInstalled: Bool { configuration != nil }

#if DEBUG
    var feedbackAnimatorForTesting: UIViewPropertyAnimator? { feedback.animatorForTesting }
    var isReadyForUITesting: Bool { configuration?.driver.canArm(input) == true }
    var readinessDiagnostic: String {
        "liftReady=\(isReadyForUITesting);eligibility=\(input);gesture=\(recognizer.state.rawValue);liftTrace=[\(gestureTrace.joined(separator: " | "))]"
    }

    // Keep test evidence bounded and free of draft content. A ready snapshot
    // before input alone cannot explain a later native gesture refusal.
    private func recordGesture(_ event: String) {
        guard recordsUITestGestures else { return }
        let peers: String = (observedTouch?.gestureRecognizers ?? []).sorted {
            let left = $0.state == .began || $0.state == .changed
            let right = $1.state == .began || $1.state == .changed
            return left && !right
        }.prefix(16).map { peer in
            let view = peer.view.map { String(String(describing: type(of: $0)).prefix(96)) } ?? "nil"
            return "\(String(describing: type(of: peer))):\(peer.state.rawValue):\(peer.isEnabled):\(view)"
        }.joined(separator: ",")
        let driver = diagnosticDriver ?? configuration?.driver
        gestureTrace.append("\(event);phase=\(String(describing: driver?.state.phase));progress=\(driver?.state.progress ?? 0);input=\(input);touchPhase=\(observedTouch?.phase.rawValue ?? -1);peers=[\(peers)]")
        if gestureTrace.count > 12 { gestureTrace.removeFirst(gestureTrace.count - 12) }
        // The native transport can disappear during handoff. Keep bounded,
        // observation-ignored evidence on the driver that began this gesture.
        diagnosticDriver?.lastNativeLiftReceipt = gestureTrace.joined(separator: " | ")
    }
#endif

#if DEBUG
    func recordHostLifecycle(_ event: String) {
        guard configuration?.driver.state.phase == .armed || configuration?.driver.state.phase == .lifting else { return }
        recordGesture("host=\(event)")
    }
#endif

    private var input: SurfaceLiftEligibility {
        configuration?.eligibility(nativeInput()) ?? nativeInput()
    }

    func checkReadiness() {
        let current = input
        if !current.allowsLift {
            feedback.setReady(false)
            let driver = configuration?.driver
            let returning = driver?.isPreparingReturn == true
                || (driver?.state.phase == .settling
                    && driver?.state.pendingSettlement?.destination == .full)
#if DEBUG
            if driver?.state.phase == .armed || driver?.state.phase == .lifting {
                recordGesture("readinessInvalidated")
            }
#endif
            // A remounted editor must settle before the next Lift. Its temporary
            // native readiness cannot cancel Return preparation (still Card) or
            // the subsequent Full settlement. Explicit invalidation still owns
            // scene, navigation and cancellation changes on the driver.
            if !returning { driver?.invalidate(); origin = nil }
        }
        editor?.accessibilityCustomActions = configuration != nil
            ? [UIAccessibilityCustomAction(name: "提起会话", target: self,
                                           selector: #selector(liftForAccessibility))] : nil
    }

    func cancelForDetachment() {
        feedback.resetForDetachment()
        let driver = configuration?.driver
        if driver?.state.phase == .armed || driver?.state.phase == .lifting {
            driver?.invalidate()
        }
        origin = nil
#if DEBUG
        diagnosticDriver = nil
#endif
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let accepted = configuration?.driver.canArm(input) == true
#if DEBUG
        recordGesture("shouldBegin=\(accepted)")
#endif
        return accepted
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let editorTouch = touch.view.map { view in
            editor.map { view === $0 || view.isDescendant(of: $0) } ?? false
        } ?? false
        let accepted = touch.view === surface || (editorTouch && configuration?.driver.canArm(input) == true)
        if accepted { feedback.prepare() }
#if DEBUG
        if recordsUITestGestures { observedTouch = touch }
        recordGesture("receive=\(accepted);view=\(String(describing: touch.view.map { type(of: $0) }))")
#endif
        return accepted
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let current = input
        guard gestureRecognizer === recognizer, let driver = configuration?.driver,
              current.allowsLift,
              driver.canArm(current) || (origin != nil
                  && (driver.state.phase == .armed || driver.state.phase == .lifting)),
              let editor, let view = otherGestureRecognizer.view else { return false }
        // Native caret/selection gestures wait only while this touch can Lift.
        // Editing, marked text and keyboard transitions retain native priority.
        return view === editor || view.isDescendant(of: editor)
    }

    @objc private func gestureChanged(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            feedback.setReady(false)
        }
#if DEBUG
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            let point = surface?.window.map { gesture.location(in: $0) }
            recordGesture("terminal=\(gesture.state.rawValue);point=\(String(describing: point));origin=\(String(describing: origin))")
            diagnosticDriver = nil
        }
#endif
        guard let configuration, let window = surface?.window else { return }
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
#if DEBUG
            recordedFirstChange = false
            diagnosticDriver = configuration.driver
#endif
            origin = configuration.driver.arm(input, conversationID: configuration.conversationID) ? point : nil
            feedback.setReady(origin != nil)
#if DEBUG
            recordGesture("began;point=\(point);origin=\(String(describing: origin))")
#endif
        case .changed:
            guard let origin else { return }
#if DEBUG
            if !recordedFirstChange {
                recordGesture("firstChanged;point=\(point)")
                recordedFirstChange = true
            }
#endif
            let displacement = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            if !configuration.driver.drag(displacement: displacement,
                                          eligibility: input, locationInWindow: point) {
#if DEBUG
                recordGesture("dragRefused;point=\(point);origin=\(origin)")
#endif
                self.origin = nil
            }
            feedback.setReady(configuration.driver.state.phase == .armed && self.origin != nil)
        case .ended, .cancelled, .failed:
            defer { origin = nil }
            guard let origin else { return }
            guard input.allowsLift else { configuration.driver.invalidate(); return }
            Self.finish(driver: configuration.driver, origin: origin, point: point,
                        eligibility: input, cancelled: gesture.state != .ended)
        default:
            break
        }
    }

    static func finish(driver: SurfaceLiftController, origin: CGPoint, point: CGPoint,
                       eligibility: SurfaceLiftEligibility, cancelled: Bool) {
        finish(driver: driver,
            displacement: CGSize(width: point.x - origin.x, height: point.y - origin.y),
            point: point, eligibility: eligibility, cancelled: cancelled)
    }

    static func finish(driver: SurfaceLiftController, displacement: CGSize, point: CGPoint,
                       eligibility: SurfaceLiftEligibility, cancelled: Bool) {
        if !cancelled && !driver.drag(displacement: displacement,
                                      eligibility: eligibility, locationInWindow: point) {
            driver.invalidate()
            return
        }
        _ = driver.end(cancelled: cancelled)
    }

    @objc private func liftForAccessibility() -> Bool {
        guard let configuration, configuration.driver.arm(input) else { return false }
        guard configuration.driver.drag(displacement: CGSize(width: 0, height: -180),
                                        eligibility: input) else { return false }
        _ = configuration.driver.end()
        return true
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        if let window = surface?.window { keyboardWindow = window }
        // A Split editor is parked between activations. Keep receiving its
        // Window's completion notifications so readiness cannot freeze mid-hide.
        guard let window = surface?.window ?? keyboardWindow else { return }
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
