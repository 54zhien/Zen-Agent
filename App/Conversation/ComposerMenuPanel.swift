import SwiftUI
import UIKit

/// One material surface per menu level. UIKit changes its geometry while the
/// hosted labels retain their font size and are revealed through the glass.
@MainActor
final class ComposerMenuPanel {
    let glass: UIVisualEffectView
    let content: UIHostingController<ComposerActionMenuView>
    private(set) var contentSize = CGSize.zero
    private let anchorsContentToBottom: Bool

    struct Pose {
        let frame: CGRect
        let radius: CGFloat
        let contentAlpha: CGFloat
    }

    init(rootView: ComposerActionMenuView) {
        anchorsContentToBottom = rootView.level == .actions
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
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

    func place(_ frame: CGRect, radius: CGFloat = 28, contentAlpha: CGFloat = 1) {
        glass.frame = frame
        glass.cornerConfiguration = .corners(radius: .fixed(Double(radius)))
        // The root reveals upward from +; a child reveals its header and then
        // its rows downward from the selected parent row. Neither scales text.
        content.view.frame = CGRect(x: 0, y: anchorsContentToBottom ? frame.height - contentSize.height : 0,
            width: contentSize.width, height: contentSize.height)
        content.view.alpha = contentAlpha
    }

    var displayedPose: Pose {
        let frame = glass.layer.presentation()?.frame ?? glass.frame
        let alpha = content.view.layer.presentation().map { CGFloat($0.opacity) } ?? content.view.alpha
        return Pose(frame: frame, radius: min(glass.effectiveRadius(corner: .bottomLeft),
            min(frame.width, frame.height) / 2), contentAlpha: alpha)
    }

    func restore(_ pose: Pose) {
        place(pose.frame, radius: pose.radius, contentAlpha: pose.contentAlpha)
    }

    func remove() {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        glass.removeFromSuperview()
    }
}
