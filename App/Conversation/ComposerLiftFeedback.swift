import UIKit

/// A short visual size cue that leaves the Composer's logical geometry untouched.
@MainActor
final class ComposerLiftFeedback {
    private weak var surface: UIView?
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private var animator: UIViewPropertyAnimator?
    private var ready = false
#if DEBUG
    var animatorForTesting: UIViewPropertyAnimator? { animator }
#endif

    init(surface: UIView) {
        self.surface = surface
        haptic.prepare()
    }

    func prepare() {
        haptic.prepare()
    }

    func setReady(_ value: Bool) {
        guard ready != value else { return }
        guard let surface else { ready = false; return }
        ready = value

        let visibleTransform = surface.layer.presentation()?.sublayerTransform
            ?? surface.layer.sublayerTransform
        animator?.stopAnimation(true)
        animator = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer.sublayerTransform = visibleTransform
        CATransaction.commit()

        let target = value
            ? CATransform3DMakeScale(1.045, 1.045, 1)
            : CATransform3DIdentity
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard !reduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.sublayerTransform = target
            CATransaction.commit()
            if value {
                haptic.impactOccurred(intensity: 0.45)
            }
            haptic.prepare()
            return
        }

        let next = UIViewPropertyAnimator(
            duration: 0.26,
            timingParameters: UISpringTimingParameters(dampingRatio: value ? 0.78 : 0.9)
        )
        next.addAnimations { [weak surface] in
            surface?.layer.sublayerTransform = target
        }
        animator = next
        next.startAnimation()
        if value {
            // The single soft impact lands with the spring that enlarges the glass.
            haptic.impactOccurred(intensity: 0.45)
        }
        haptic.prepare()
    }

    /// Detachment can outlive UIKit's cancelled recognizer callback.
    func resetForDetachment() {
        ready = false
        animator?.stopAnimation(true)
        animator = nil
        guard let surface else { haptic.prepare(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
        haptic.prepare()
    }
}
