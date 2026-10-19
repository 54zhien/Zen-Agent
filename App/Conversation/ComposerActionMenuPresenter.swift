import SwiftUI
import UIKit

/// One same-window presentation preserves the editor and keyboard context.
/// UIKit transports the whole panel; SwiftUI owns only its root/model contents.
@MainActor
final class ComposerActionMenuPresenter: UIViewController {
    private weak var sourceView: UIView?
    private let presentation: ComposerActionMenuState
    private let onSelect: (ModelID) -> Void
    private let onDismiss: (ComposerActionMenuPresenter) -> Void
    private let outside = UIControl()
    private var maximumSize = CGSize.zero
    private var panelSize = CGSize.zero
    private var isClosing = false
    private var animator: UIViewPropertyAnimator?
    private lazy var content = UIHostingController(rootView: menuView())

    init(sourceView: UIView, presentation: ComposerActionMenuState,
         onSelect: @escaping (ModelID) -> Void,
         onDismiss: @escaping (ComposerActionMenuPresenter) -> Void) {
        self.sourceView = sourceView
        self.presentation = presentation
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    override func loadView() {
        let overlay = ComposerActionMenuOverlay()
        overlay.menu = self
        overlay.backgroundColor = .clear
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.accessibilityViewIsModal = true
        view = overlay
        outside.accessibilityElementsHidden = true
        outside.addTarget(self, action: #selector(closeFromOutside), for: .touchUpInside)
        view.addSubview(outside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func menuView() -> ComposerActionMenuView {
        ComposerActionMenuView(presentation: presentation, maximumSize: maximumSize,
            onSelect: { [weak self] modelID in
                guard let self, !self.isClosing else { return }
                self.onSelect(modelID)
                self.close()
            }, onSizeChanged: { [weak self] size in self?.panelSize = size })
    }

    func show(in window: UIWindow) {
        loadViewIfNeeded()
        guard let placement = placement(in: window) else { return }
        maximumSize = placement.size
        overrideUserInterfaceStyle = sourceView?.traitCollection.userInterfaceStyle ?? .unspecified
        view.frame = window.bounds
        content.view.backgroundColor = .clear
        content.safeAreaRegions = []
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
        beginAppearanceTransition(true, animated: false)
        window.addSubview(view)
        updatePlacement()
        view.layoutIfNeeded()
        content.view.layoutIfNeeded()
        endAppearanceTransition()
        content.view.isUserInteractionEnabled = false
        content.view.transform = collapsedTransform
        animate(duration: 0.38, dampingRatio: 0.72) {
            self.content.view.transform = .identity
            self.sourceView?.alpha = 0
        } completion: { [weak self] in
            guard let self, !self.isClosing, self.view.superview != nil else { return }
            self.content.view.isUserInteractionEnabled = true
            UIAccessibility.post(notification: .layoutChanged, argument: self.content.view)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outside.frame = view.bounds
        updatePlacement()
    }

    private func updatePlacement() {
        guard let window = view.window, let placement = placement(in: window) else { return }
        let frame = view.convert(placement, from: window)
        if maximumSize != frame.size {
            maximumSize = frame.size
            content.rootView = menuView()
        }
        // A transformed view's frame is undefined; preserve its logical bounds.
        content.view.bounds = CGRect(origin: .zero, size: frame.size)
        content.view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func placement(in window: UIWindow) -> CGRect? {
        guard let sourceView else { return nil }
        let source = sourceView.convert(sourceView.bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 8, dy: 8)
        let width = min(safe.width, UIFontMetrics(forTextStyle: .body).scaledValue(for: 250,
            compatibleWith: sourceView.traitCollection))
        let bottom = min(source.maxY, safe.maxY)
        let height = min(window.bounds.height * 0.65, max(44, bottom - safe.minY))
        let x = min(max(safe.minX, source.minX), safe.maxX - width)
        return CGRect(x: x, y: bottom - height, width: width, height: height)
    }

    private var collapsedTransform: CGAffineTransform {
        anchoredTransform(scale: 0.02)
    }

    private func anchoredTransform(scale: CGFloat) -> CGAffineTransform {
        guard !UIAccessibility.isReduceMotionEnabled, let sourceView else { return .identity }
        let source = view.convert(sourceView.bounds, from: sourceView)
        // Keep the actual + center fixed throughout uniform scaling, including
        // a shifted Sidebar/Split Composer. Both text and glass ride this view.
        return CGAffineTransform(translationX: (source.midX - content.view.center.x) * (1 - scale),
            y: (source.midY - content.view.center.y) * (1 - scale)).scaledBy(x: scale, y: scale)
    }

    fileprivate func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard view.bounds.contains(point) else { return nil }
        let panel = CGRect(x: content.view.bounds.minX, y: content.view.bounds.maxY - panelSize.height,
                           width: panelSize.width, height: panelSize.height)
        if !isClosing, content.view.isUserInteractionEnabled,
           panel.contains(content.view.convert(point, from: view)) {
            return content.view.hitTest(content.view.convert(point, from: view), with: event)
        }
        return outside
    }

    @objc private func closeFromOutside() { close() }

    func close(animated: Bool = true) {
        guard viewIfLoaded?.superview != nil else { return }
        if !animated {
            isClosing = true
            animator?.stopAnimation(true)
            animator = nil
            finishDismissal()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        let wasOpen = content.view.isUserInteractionEnabled
        content.view.isUserInteractionEnabled = false
        let displayed = content.view.layer.presentation()?.affineTransform()
        animator?.stopAnimation(true)
        animator = nil
        if let displayed { content.view.transform = displayed }
        if wasOpen, !UIAccessibility.isReduceMotionEnabled {
            // A small recoil before contraction stays visible; undershooting
            // a near-zero scale would instead flip the glass through its anchor.
            animate(duration: 0.09, dampingRatio: 1) {
                self.content.view.transform = self.anchoredTransform(scale: 1.025)
            } completion: { [weak self] in self?.collapse() }
        } else {
            collapse()
        }
    }

    private func collapse() {
        animate(duration: 0.30, dampingRatio: 0.86) {
            self.content.view.transform = self.collapsedTransform
            self.sourceView?.alpha = 1
        } completion: { [weak self] in self?.finishDismissal() }
    }

    private func animate(duration: TimeInterval, dampingRatio: CGFloat, _ changes: @escaping () -> Void,
                         completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(changes)
            completion()
        } else {
            // Animate the native host transform without sending an outer
            // SwiftUI transaction through the live glass hierarchy. Keeping
            // its alpha at 1 also avoids group-opacity composition while shrinking.
            let animation = UIViewPropertyAnimator(duration: duration,
                dampingRatio: dampingRatio, animations: changes)
            animator = animation
            animation.addCompletion { [weak self] position in
                guard position == .end else { return }
                self?.animator = nil
                completion()
            }
            animation.startAnimation()
        }
    }

    private func finishDismissal() {
        guard view.superview != nil else { return }
        sourceView?.alpha = 1
        beginAppearanceTransition(false, animated: false)
        view.removeFromSuperview()
        endAppearanceTransition()
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        onDismiss(self)
        if sourceView?.window != nil {
            UIAccessibility.post(notification: .layoutChanged, argument: sourceView)
        }
    }
}

private final class ComposerActionMenuOverlay: UIView {
    weak var menu: ComposerActionMenuPresenter?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        menu?.hitTest(point, with: event)
    }

    override func accessibilityPerformEscape() -> Bool {
        menu?.close()
        return true
    }
}
