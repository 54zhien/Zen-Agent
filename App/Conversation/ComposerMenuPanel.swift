import SwiftUI
import UIKit

/// Each level owns its material. The root's content scales on a fixed layout
/// canvas so opening does not reflow labels or change their final alignment.
@MainActor
final class ComposerMenuPanel {
    let glass: UIVisualEffectView
    let content: UIHostingController<ComposerActionMenuView>
    private let material: UIGlassEffect
    private let dismissalMask = UIView()
    private(set) var contentSize = CGSize.zero
    private let centersContent: Bool

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

    func setDismissalVisibility(_ opacity: CGFloat) {
        // A direct effect-view mask is forwarded to the material and content.
        // Keep effect/ancestor alpha at one and avoid native dematerialization.
        dismissalMask.frame = CGRect(origin: .zero, size: CGSize(
            width: max(contentSize.width, glass.bounds.width),
            height: max(contentSize.height, glass.bounds.height)))
        dismissalMask.backgroundColor = UIColor(white: 1, alpha: max(0, min(1, opacity)))
        // UIKit copies effect-view masks; reassign after changing the original.
        glass.mask = nil
        glass.mask = dismissalMask
    }

    func place(_ frame: CGRect, radius: CGFloat = 28, contentAlpha: CGFloat = 1,
               contentScale: CGFloat = 1) {
        glass.frame = frame
        glass.cornerConfiguration = .corners(radius: .fixed(Double(radius)))
        content.view.bounds = CGRect(origin: .zero, size: contentSize)
        content.view.center = centersContent
            ? CGPoint(x: frame.width / 2, y: frame.height / 2)
            : CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        content.view.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        content.view.alpha = contentAlpha
    }

    func remove() {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        glass.removeFromSuperview()
    }
}
