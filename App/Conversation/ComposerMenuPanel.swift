import SwiftUI
import UIKit

/// Each level owns its material. The root's content scales on a fixed layout
/// canvas so opening does not reflow labels or change their final alignment.
@MainActor
final class ComposerMenuPanel {
    let glass: UIVisualEffectView
    let content: UIHostingController<ComposerActionMenuView>
    private let material: UIGlassEffect
    private(set) var contentSize = CGSize.zero
    private var contentScale: CGFloat = 1
    private let centersContent: Bool

    struct Pose {
        let frame: CGRect
        let radius: CGFloat
        let contentAlpha: CGFloat
        let contentScale: CGFloat
    }

    init(rootView: ComposerActionMenuView) {
        centersContent = rootView.level == .actions
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        material = effect
        glass = UIVisualEffectView(effect: effect)
        glass.cornerConfiguration = .corners(radius: 28)
        glass.contentView.clipsToBounds = true
        content = UIHostingController(rootView: rootView)
        content.view.backgroundColor = .clear
        content.safeAreaRegions = []
    }

    func install(in parent: UIViewController) {
        parent.addChild(content)
        parent.view.addSubview(glass)
        glass.contentView.addSubview(content.view)
        content.didMove(toParent: parent)
    }

    func measure(in maximumSize: CGSize) -> CGSize {
        let fitted = content.sizeThatFits(in: maximumSize)
        contentSize = CGSize(width: maximumSize.width, height: min(maximumSize.height, ceil(fitted.height)))
        return contentSize
    }

    func showMaterial(_ visible: Bool) {
        // Animate the effect itself so UIKit materializes the glass without
        // fading the entire visual-effect hierarchy through an offscreen pass.
        glass.effect = visible ? material : nil
    }

    func place(_ frame: CGRect, radius: CGFloat = 28, contentAlpha: CGFloat = 1,
               contentScale: CGFloat = 1) {
        glass.frame = frame
        glass.cornerConfiguration = .corners(radius: .fixed(Double(radius)))
        self.contentScale = contentScale
        content.view.bounds = CGRect(origin: .zero, size: contentSize)
        content.view.center = centersContent
            ? CGPoint(x: frame.width / 2, y: frame.height / 2)
            : CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        content.view.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        content.view.alpha = contentAlpha
    }

    var displayedPose: Pose {
        let frame = glass.layer.presentation()?.frame ?? glass.frame
        let alpha = content.view.layer.presentation().map { CGFloat($0.opacity) } ?? content.view.alpha
        let scale = content.view.layer.presentation().map { CGFloat($0.transform.m11) } ?? contentScale
        return Pose(frame: frame, radius: min(glass.effectiveRadius(corner: .bottomLeft),
            min(frame.width, frame.height) / 2), contentAlpha: alpha, contentScale: scale)
    }

    func restore(_ pose: Pose) {
        place(pose.frame, radius: pose.radius, contentAlpha: pose.contentAlpha,
              contentScale: pose.contentScale)
    }

    func remove() {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        glass.removeFromSuperview()
    }
}
