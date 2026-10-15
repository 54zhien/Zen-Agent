import UIKit

/// A quiet page-colored backing under the floating input, without another
/// hierarchy snapshot competing with scrolling or the keyboard animation.
final class ComposerBottomFadeLayer: CAGradientLayer {
    override init() {
        super.init()
        name = "zen-composer-bottom-fade"
        startPoint = CGPoint(x: 0.5, y: 0)
        endPoint = CGPoint(x: 0.5, y: 1)
        locations = [0, 0.25, 0.6, 1]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    @MainActor
    func update(bounds: CGRect, composerFrame: CGRect, bottom: CGFloat, traits: UITraitCollection) {
        let end = min(bounds.maxY, max(bounds.minY, bottom))
        let start = max(bounds.minY, composerFrame.minY - 36)
        let color = UIColor.systemBackground.resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: bounds.minX, y: start, width: bounds.width, height: max(0, end - start))
        colors = [CGFloat(0), 0.28, 0.78, 1].map { color.withAlphaComponent($0).cgColor }
        isHidden = bounds.isEmpty || composerFrame.isEmpty || end <= start
        CATransaction.commit()
    }
}
