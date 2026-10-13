import UIKit

/// Readiness decoration has no bearing on the Composer's measured layout.
@MainActor
final class ComposerLiftFeedback {
    private weak var surface: UIView?
    private let outline = CAShapeLayer()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var ready = false

    init(surface: UIView) {
        self.surface = surface
        outline.name = "zen-composer-lift-ready"
        outline.fillColor = UIColor.clear.cgColor
        outline.lineWidth = 1.5
        outline.lineCap = .round
        outline.lineJoin = .round
        outline.opacity = 0
        surface.layer.addSublayer(outline)
    }

    func setReady(_ value: Bool) {
        guard ready != value else { return }
        ready = value
        outline.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.opacity = value ? 1 : 0
        if value, let surface {
            outline.frame = surface.bounds
            outline.contentsScale = surface.window?.screen.scale ?? surface.traitCollection.displayScale
            outline.strokeColor = surface.tintColor.resolvedColor(with: surface.traitCollection).cgColor
            let radius = max(0, surface.effectiveRadius(corner: .topLeft) - 2)
            let path = UIBezierPath(roundedRect: surface.bounds.insetBy(dx: 2, dy: 2), cornerRadius: radius)
            path.move(to: CGPoint(x: surface.bounds.midX - 7, y: -7))
            path.addLine(to: CGPoint(x: surface.bounds.midX, y: -13))
            path.addLine(to: CGPoint(x: surface.bounds.midX + 7, y: -7))
            outline.path = path.cgPath
        }
        CATransaction.commit()
        guard value else { return }
        haptic.impactOccurred(intensity: 0.55)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 0
        lift.toValue = -3
        lift.duration = 0.55
        lift.autoreverses = true
        lift.repeatCount = .infinity
        lift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outline.add(lift, forKey: "ready-lift")
    }
}
