import UIKit

/// A leading-edge pan consumes input dismissal before Sidebar transport. It
/// lives on the Window so app-owned detail overlays participate as well.
@MainActor
final class ComposerSidebarInputDismissal: NSObject, UIGestureRecognizerDelegate {
    private let pan = ComposerInputDismissPan()
    private weak var window: UIWindow?
    private let isPresented: () -> Bool
    private let direction: () -> CGFloat
    private let dismiss: () -> Void
    private var admittedTouch = false

    init(isPresented: @escaping () -> Bool, direction: @escaping () -> CGFloat,
         dismiss: @escaping () -> Void) {
        self.isPresented = isPresented
        self.direction = direction
        self.dismiss = dismiss
        super.init()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.addTarget(self, action: #selector(changed))
    }

    func attach(to next: UIWindow?) {
        guard window !== next else { return }
        window?.removeGestureRecognizer(pan)
        admittedTouch = false
        window = next
        next?.addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        admittedTouch = false
        guard let window, touch.view?.window === window, isPresented(),
              window.windowScene?.activationState == .foregroundActive else { return false }
        let x = touch.location(in: window).x
        let distance = direction() > 0 ? x - window.bounds.minX : window.bounds.maxX - x
        // Match a screen-edge intent, not drags starting in the effort rail.
        admittedTouch = distance >= 0 && distance <= 24
        return admittedTouch
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard admittedTouch, isPresented(), let window else { return false }
        let velocity = pan.velocity(in: window)
        let motion = velocity == .zero ? pan.translation(in: window) : velocity
        return motion.x.isFinite && motion.y.isFinite
            && motion.x * direction() > 0 && abs(motion.x) > abs(motion.y) * 1.1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A recognized dismissal owns this whole touch; Sidebar cannot begin
        // later in the same swipe after the keyboard/menu becomes hidden.
        admittedTouch && isPresented() && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer is ComposerInputDismissPan)
    }

    @objc private func changed() {
        if pan.state == .began, admittedTouch, isPresented() { dismiss() }
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
            admittedTouch = false
        }
    }
}

/// Lets Sidebar's general failure policy yield to the input owner's pan.
final class ComposerInputDismissPan: UIPanGestureRecognizer {}
