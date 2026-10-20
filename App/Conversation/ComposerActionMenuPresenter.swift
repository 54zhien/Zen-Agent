import SwiftUI
import UIKit

/// A same-window hierarchy keeps the editor and its keyboard owner intact.
/// Native glass geometry, content reveal and source icon share one animator.
@MainActor
final class ComposerActionMenuPresenter: UIViewController {
    private weak var sourceView: UIView?
    private weak var alignmentView: UIView?
    private let presentation: ComposerActionMenuState
    private let onSelect: (ModelID) -> Void
    private let onDismiss: (ComposerActionMenuPresenter) -> Void
    private let outside = UIControl()
    private let parentReturn = UIControl()
    private let sourceIcon = UIImageView()
    private var sourceIconFrame = CGRect.zero
    private var rootPanel: ComposerMenuPanel?
    private var childPanel: ComposerMenuPanel?
    private var placementFrame = CGRect.zero
    private var rootFrame = CGRect.zero
    private var childFrame = CGRect.zero
    private var modelRow = CGRect.zero
    private var isClosing = false
    private var isTransitioning = false
    private var animator: UIViewPropertyAnimator?

    init(sourceView: UIView, alignmentView: UIView, presentation: ComposerActionMenuState,
         onSelect: @escaping (ModelID) -> Void,
         onDismiss: @escaping (ComposerActionMenuPresenter) -> Void) {
        self.sourceView = sourceView
        self.alignmentView = alignmentView
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
        parentReturn.isAccessibilityElement = false
        parentReturn.accessibilityElementsHidden = true
        parentReturn.addTarget(self, action: #selector(returnToActions), for: .touchUpInside)
        view.addSubview(parentReturn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makePanel(_ level: ComposerActionMenuLevel) -> ComposerMenuPanel {
        ComposerMenuPanel(rootView: ComposerActionMenuView(level: level, presentation: presentation,
            maximumSize: placementFrame.size,
            onSelect: { [weak self] modelID in
                guard let self, !self.isClosing, !self.isTransitioning else { return }
                self.onSelect(modelID)
                self.close()
            }, onOpenModels: { [weak self] row in self?.openModels(from: row) },
            onReturn: { [weak self] in self?.returnToActions() }))
    }

    func show(in window: UIWindow) {
        loadViewIfNeeded()
        guard let placement = placement(in: window) else { return }
        placementFrame = placement
        overrideUserInterfaceStyle = sourceView?.traitCollection.userInterfaceStyle ?? .unspecified
        view.frame = window.bounds
        let root = makePanel(.actions)
        root.showMaterial(false)
        rootPanel = root
        root.install(in: self)
        beginAppearanceTransition(true, animated: false)
        window.addSubview(view)
        rootFrame = fittedFrame(for: root)
        view.layoutIfNeeded()
        endAppearanceTransition()
        guard view.superview != nil else { return }
        root.content.view.isUserInteractionEnabled = false
        root.place(sourceFrame, radius: sourceRadius, contentAlpha: 0,
                   contentScale: collapsedContentScale)
        if let button = sourceView as? UIButton, let imageView = button.imageView {
            sourceIcon.image = imageView.image
            sourceIcon.preferredSymbolConfiguration = button.preferredSymbolConfigurationForImage(in: .normal)
            sourceIcon.tintColor = button.tintColor
            sourceIcon.contentMode = .scaleAspectFit
            sourceIcon.isUserInteractionEnabled = false
            sourceIcon.accessibilityElementsHidden = true
            sourceIconFrame = view.convert(imageView.bounds, from: imageView)
            // The departing glyph must not be clipped by the circular glass
            // or inherit the scale of the menu's content canvas.
            view.addSubview(sourceIcon)
            sourceIcon.frame = sourceIconFrame
            sourceIcon.alpha = 1
            sourceView?.alpha = 0
        }
        root.glass.layoutIfNeeded()
        isTransitioning = true
        expand(root)
    }

    private func expand(_ root: ComposerMenuPanel) {
        animate(duration: 0.44, dampingRatio: 0.72) {
            root.showMaterial(true)
            root.place(self.rootFrame)
            self.sourceIcon.frame = self.sourceIconFrame.offsetBy(
                dx: self.sourceFrame.width / 2, dy: -self.sourceFrame.height / 2)
            self.sourceIcon.alpha = 0
            self.sourceView?.alpha = 0
        } completion: { [weak self] in
            guard let self, !self.isClosing else { return }
            self.isTransitioning = false
            root.content.view.isUserInteractionEnabled = true
            UIAccessibility.post(notification: .layoutChanged, argument: root.content.view)
        }
    }

    private var collapsedContentScale: CGFloat {
        let size = rootPanel?.contentSize ?? rootFrame.size
        return min(1, min(sourceFrame.width / max(1, size.width),
                          sourceFrame.height / max(1, size.height)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outside.frame = view.bounds
        parentReturn.frame = parentFrame
        guard let window = view.window, let placement = placement(in: window),
              placement != placementFrame else { return }
        // A moving keyboard or rotation invalidates the source geometry. Close
        // without moving or reparenting the retained editor to chase that change.
        close(animated: false)
    }

    private func placement(in window: UIWindow) -> CGRect? {
        guard let sourceView, let alignmentView else { return nil }
        let aligned = alignmentView.convert(alignmentView.bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 8, dy: 8)
        let width = min(safe.width, UIFontMetrics(forTextStyle: .body).scaledValue(for: 250,
            compatibleWith: sourceView.traitCollection), max(0, safe.maxX - aligned.minX))
        let bottom = aligned.maxY
        let height = min(window.bounds.height * 0.65, max(44, bottom - safe.minY))
        return CGRect(x: aligned.minX, y: bottom - height, width: width, height: height)
    }

    private func fittedFrame(for panel: ComposerMenuPanel) -> CGRect {
        let size = panel.measure(in: placementFrame.size)
        return view.convert(CGRect(x: placementFrame.minX, y: placementFrame.maxY - size.height,
            width: size.width, height: size.height), from: view.window)
    }

    private var sourceFrame: CGRect {
        guard let sourceView else { return .zero }
        return view.convert(sourceView.bounds, from: sourceView)
    }

    private var sourceRadius: CGFloat { min(sourceFrame.width, sourceFrame.height) / 2 }
    private var parentFrame: CGRect { rootFrame.offsetBy(dx: 0, dy: -12) }

    private func openModels(from row: CGRect) {
        guard !isClosing, !isTransitioning, childPanel == nil,
              !presentation.models.isEmpty, let root = rootPanel else { return }
        WorkspaceHaptics.shared.play(.control)
        modelRow = row
        let origin = view.convert(row, from: root.content.view)
        let child = makePanel(.models)
        childPanel = child
        child.install(in: self)
        childFrame = fittedFrame(for: child)
        child.place(origin, radius: min(28, origin.height / 2), contentAlpha: 0)
        child.glass.layoutIfNeeded()
        parentReturn.frame = parentFrame
        root.content.view.isUserInteractionEnabled = false
        root.glass.accessibilityElementsHidden = true
        child.content.view.isUserInteractionEnabled = false
        isTransitioning = true
        animate(duration: 0.30, dampingRatio: 1) {
            root.place(self.parentFrame, contentAlpha: 0.4)
            child.place(self.childFrame)
        } completion: { [weak self] in
            guard let self, !self.isClosing else { return }
            self.isTransitioning = false
            child.content.view.isUserInteractionEnabled = true
            UIAccessibility.post(notification: .layoutChanged, argument: child.content.view)
        }
    }

    @objc private func returnToActions() {
        guard !isClosing, !isTransitioning, let child = childPanel, let root = rootPanel else { return }
        WorkspaceHaptics.shared.play(.control)
        isTransitioning = true
        child.content.view.isUserInteractionEnabled = false
        let target = modelRow.offsetBy(dx: rootFrame.minX, dy: rootFrame.minY)
        animate(duration: 0.30, dampingRatio: 1) {
            root.place(self.rootFrame)
            child.place(target, radius: min(28, target.height / 2), contentAlpha: 0)
        } completion: { [weak self] in
            guard let self, !self.isClosing else { return }
            child.remove()
            self.childPanel = nil
            self.isTransitioning = false
            root.glass.accessibilityElementsHidden = false
            root.content.view.isUserInteractionEnabled = true
            UIAccessibility.post(notification: .layoutChanged, argument: root.content.view)
        }
    }

    fileprivate func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard view.bounds.contains(point) else { return nil }
        if isClosing { return view }
        if isTransitioning {
            if rootFrame.union(parentFrame).contains(point)
                || (childPanel != nil && childFrame.contains(point)) {
                return view
            }
            return outside
        }
        if let child = childPanel {
            if child.glass.frame.contains(point) {
                return child.glass.hitTest(child.glass.convert(point, from: view), with: event)
            }
            if rootPanel?.glass.frame.contains(point) == true { return parentReturn }
        } else if let root = rootPanel, root.glass.frame.contains(point) {
            return root.glass.hitTest(root.glass.convert(point, from: view), with: event)
        }
        return outside
    }

    @objc private func closeFromOutside() { close() }

    func close(animated: Bool = true) {
        guard viewIfLoaded?.superview != nil else { return }
        if !animated {
            isClosing = true
            stopAnimator()
            finishDismissal()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        rootPanel?.content.view.isUserInteractionEnabled = false
        childPanel?.content.view.isUserInteractionEnabled = false
        stopAnimator()
        collapse()
    }

    private func collapse() {
        animate(duration: 0.35, dampingRatio: 0.86) {
            self.rootPanel?.showMaterial(true)
            // Retire the upper material during contraction so model selection
            // returns through one source circle, without glass over the glyph.
            self.childPanel?.showMaterial(false)
            self.rootPanel?.place(self.sourceFrame, radius: self.sourceRadius,
                contentAlpha: 0, contentScale: self.collapsedContentScale)
            self.childPanel?.place(self.sourceFrame, radius: self.sourceRadius, contentAlpha: 0)
            self.sourceIcon.frame = self.sourceIconFrame
            self.sourceIcon.alpha = 0
        } completion: { [weak self] in
            guard let self else { return }
            self.childPanel?.remove()
            self.childPanel = nil
            self.animate(duration: 0.12, dampingRatio: 1) {
                self.rootPanel?.showMaterial(false)
                self.sourceIcon.alpha = 1
            } completion: { [weak self] in self?.finishDismissal() }
        }
    }

    private func stopAnimator() {
        let rootPose = rootPanel?.displayedPose
        let childPose = childPanel?.displayedPose
        let iconFrame = sourceIcon.layer.presentation()?.frame ?? sourceIcon.frame
        let iconAlpha = sourceIcon.layer.presentation().map { CGFloat($0.opacity) } ?? sourceIcon.alpha
        animator?.stopAnimation(true)
        animator = nil
        UIView.performWithoutAnimation {
            if let rootPose { self.rootPanel?.restore(rootPose) }
            if let childPose { self.childPanel?.restore(childPose) }
            self.sourceIcon.frame = iconFrame
            self.sourceIcon.alpha = iconAlpha
        }
    }

    private func animate(duration: TimeInterval, dampingRatio: CGFloat, _ changes: @escaping () -> Void,
                         completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(changes)
            completion()
        } else {
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
        childPanel?.remove()
        rootPanel?.remove()
        childPanel = nil
        rootPanel = nil
        sourceIcon.removeFromSuperview()
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
        menu?.escape()
        return true
    }
}

extension ComposerActionMenuPresenter {
    fileprivate func escape() {
        if childPanel != nil, !isTransitioning { returnToActions() }
        else { close() }
    }
}
