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
    private let sourceIcon = UIImageView()
    private var sourceIconFrame = CGRect.zero
    private var rootPanel: ComposerMenuPanel?
    private var details: ComposerMenuDetailPresenter?
    private let windowCornerGeometry = WindowCornerGeometry()
    private var rootMenuCornerRadius: CGFloat = 0
    private var placementFrame = CGRect.zero
    private var rootFrame = CGRect.zero
    private var isClosing = false
    private var isTransitioning = false
    private var animator: UIViewPropertyAnimator?
    private var collapseDisplayLink: CADisplayLink?
    private var collapsingCircle: CGRect?
    private var collapseStartSize = CGSize.zero
    private var circleFadeAnimator: UIViewPropertyAnimator?
    private var isFadingCircle = false
    private var hasFinishedCollapse = false
    private var hasFinishedFade = false
    private let menuMotionDuration: TimeInterval = 0.44
    private let menuMotionDamping: CGFloat = 0.72

    init(sourceView: UIView, alignmentView: UIView, presentation: ComposerActionMenuState,
         onSelect: @escaping (ModelID) -> Void,
         onDismiss: @escaping (ComposerActionMenuPresenter) -> Void) {
        self.sourceView = sourceView
        self.alignmentView = alignmentView
        self.presentation = presentation
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivate),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func deactivate() { close(animated: false) }

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

    private func makePanel() -> ComposerMenuPanel {
        ComposerMenuPanel(rootView: ComposerActionMenuView(presentation: presentation,
            maximumSize: placementFrame.size,
            onOpen: { [weak self] level in self?.openDetails(level) },
            cornerRadius: rootMenuCornerRadius), expandedRadius: rootMenuCornerRadius)
    }

    func show(in window: UIWindow) {
        loadViewIfNeeded()
        guard let placement = placement(in: window) else { return }
        placementFrame = placement
        let screenRadius = windowCornerGeometry.radius(in: window)
        rootMenuCornerRadius = screenRadius - min(8, screenRadius)
        overrideUserInterfaceStyle = sourceView?.traitCollection.userInterfaceStyle ?? .unspecified
        view.frame = window.bounds
        presentation.activeLevel = .actions
        let root = makePanel()
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
                   contentScale: contentScale(fitting: sourceFrame))
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
        animate(duration: menuMotionDuration, dampingRatio: menuMotionDamping) {
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

    private func contentScale(fitting frame: CGRect) -> CGFloat {
        let size = rootPanel?.contentSize ?? rootFrame.size
        return min(1, min(frame.width / max(1, size.width),
                          frame.height / max(1, size.height)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outside.frame = view.bounds
        guard let window = view.window, let placement = placement(in: window),
              placement != placementFrame else { return }
        // A moving keyboard or rotation invalidates the source geometry. Close
        // without moving or reparenting the retained editor to chase that change.
        close(animated: false)
    }

    private func placement(in window: UIWindow) -> CGRect? {
        guard let sourceView else { return nil }
        // Equal left/bottom inset and R-inset preserve the display's lower-left
        // arc center. Composer-relative placement cannot satisfy that geometry.
        let inset = min(8, windowCornerGeometry.radius(in: window))
        let left = window.bounds.minX + inset
        let bottom = window.bounds.maxY - inset
        let width = min(window.bounds.width - 2 * inset,
            UIFontMetrics(forTextStyle: .body).scaledValue(for: 300, compatibleWith: sourceView.traitCollection))
        let height = min(window.bounds.height * 0.65, bottom - window.safeAreaInsets.top - 8)
        return CGRect(x: left, y: bottom - height, width: width, height: height)
    }

    private func fittedFrame(for panel: ComposerMenuPanel, placement: CGRect? = nil) -> CGRect {
        let placement = placement ?? placementFrame
        let size = panel.measure(in: placement.size)
        return view.convert(CGRect(x: placement.minX, y: placement.maxY - size.height,
            width: size.width, height: size.height), from: view.window)
    }

    private var sourceFrame: CGRect {
        guard let sourceView else { return .zero }
        return view.convert(sourceView.bounds, from: sourceView)
    }

    private var sourceRadius: CGFloat { min(sourceFrame.width, sourceFrame.height) / 2 }

    private var dismissalCircle: CGRect {
        guard let alignmentView else { return sourceFrame }
        let bounds = alignmentView.bounds
        let radius = alignmentView.effectiveRadius(corner: .bottomLeft)
        guard radius.isFinite, radius > 0 else { return sourceFrame }
        let diameter = min(2 * radius, min(bounds.width, bounds.height))
        // Match the Composer's lower-left arc, rather than the inset hit target.
        let circle = CGRect(x: bounds.minX, y: bounds.maxY - diameter,
                            width: diameter, height: diameter)
        return view.convert(circle, from: alignmentView)
    }

    private func openDetails(_ level: ComposerActionMenuLevel) {
        guard !isClosing, !isTransitioning, details == nil,
              let window = view.window, let root = rootPanel else { return }
        WorkspaceHaptics.shared.play(.control)
        let detail = ComposerMenuDetailPresenter(level: level, presentation: presentation,
            height: max(240, window.bounds.height * 0.43),
            onSelect: onSelect,
            onReturn: { [weak self] animator in self?.revealActions(using: animator) },
            onDismiss: { [weak self] in self?.returnToActions() })
        details = detail
        root.glass.isHidden = true
        root.glass.accessibilityElementsHidden = true
        detail.show(in: window, style: overrideUserInterfaceStyle,
                    cornerRadius: windowCornerGeometry.radius(in: window))
    }

    private func revealActions(using animator: UIViewPropertyAnimator?) {
        guard !isClosing, let root = rootPanel else { return }
        UIView.performWithoutAnimation {
            root.showMaterial(false)
            root.content.view.alpha = 0
            root.content.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            root.glass.isHidden = false
        }
        let reveal = {
            root.showMaterial(true)
            root.content.view.alpha = 1
            root.content.view.transform = .identity
        }
        if let animator { animator.addAnimations(reveal) } else { reveal() }
    }

    private func returnToActions() {
        details = nil
        guard !isClosing else { return }
        presentation.activeLevel = .actions
        rootPanel?.glass.isHidden = false
        rootPanel?.glass.accessibilityElementsHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: rootPanel?.content.view)
    }

    fileprivate func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard view.bounds.contains(point) else { return nil }
        if isClosing || details != nil { return view }
        if isTransitioning { return rootFrame.contains(point) ? view : outside }
        if let root = rootPanel, root.glass.frame.contains(point) {
            return root.glass.hitTest(root.glass.convert(point, from: view), with: event)
        }
        return outside
    }

    @objc private func closeFromOutside() { close() }

    func close(animated: Bool = true) {
        guard viewIfLoaded?.superview != nil else { return }
        if details != nil {
            details?.removeFromWindow()
            rootPanel?.showMaterial(true)
            rootPanel?.content.view.alpha = 1
            rootPanel?.content.view.transform = .identity
        }
        details = nil
        rootPanel?.glass.isHidden = false
        if !animated {
            isClosing = true
            stopAnimator()
            finishDismissal()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        rootPanel?.content.view.isUserInteractionEnabled = false
        stopAnimator()
        collapse()
    }

    private func collapse() {
        let circle = dismissalCircle
        let radius = min(circle.width, circle.height) / 2
        collapsingCircle = circle
        collapseStartSize = rootPanel?.glass.bounds.size ?? circle.size
        UIView.performWithoutAnimation {
            // Content of the live glass, independent of the shrinking menu canvas.
            // Anchor to its lower-left edge so the final glyph matches the button.
            self.sourceIcon.alpha = 0
            self.sourceView?.alpha = 0
            if let glass = self.rootPanel?.glass {
                glass.layoutIfNeeded()
                glass.contentView.addSubview(self.sourceIcon)
                self.sourceIcon.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
                self.sourceIcon.frame = CGRect(
                    x: self.sourceIconFrame.minX - circle.minX,
                    y: glass.contentView.bounds.height - (circle.maxY - self.sourceIconFrame.minY),
                    width: self.sourceIconFrame.width, height: self.sourceIconFrame.height)
            }
        }
        if !UIAccessibility.isReduceMotionEnabled {
            let link = CADisplayLink(target: self, selector: #selector(collapseDidAdvance(_:)))
            collapseDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
        animate(duration: menuMotionDuration, dampingRatio: menuMotionDamping) {
            // Keep the first part visible; the late material fade has its own animator.
            self.rootPanel?.showMaterial(true)
            self.rootPanel?.place(circle, radius: radius,
                contentAlpha: 0, contentScale: self.contentScale(fitting: circle))
        } completion: { [weak self] in
            guard let self else { return }
            self.hasFinishedCollapse = true
            self.fadeMaterialAndRevealIcon()
            self.finishIfCollapsedAndFaded()
        }
    }

    @objc private func collapseDidAdvance(_ link: CADisplayLink) {
        guard viewIfLoaded?.window != nil else {
            stopAnimator()
            finishDismissal()
            return
        }
        guard !isFadingCircle, let circle = collapsingCircle,
              let size = rootPanel?.glass.layer.presentation()?.bounds.size,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        // Read displayed size only; never replay a glass backing layer's frame.
        let remainingWidth = abs(size.width - circle.width)
        let remainingHeight = abs(size.height - circle.height)
        let tolerance = 1 / max(1, view.window?.screen.scale ?? 1)
        let widthThreshold = max(tolerance, abs(collapseStartSize.width - circle.width) * 0.10)
        let heightThreshold = max(tolerance, abs(collapseStartSize.height - circle.height) * 0.10)
        if remainingWidth <= widthThreshold, remainingHeight <= heightThreshold {
            fadeMaterialAndRevealIcon()
        }
    }

    private func fadeMaterialAndRevealIcon() {
        guard !isFadingCircle else { return }
        isFadingCircle = true
        collapseDisplayLink?.invalidate()
        collapseDisplayLink = nil
        let changes = {
            // Apple's dematerialization path: leave the effect view at alpha 1.
            self.rootPanel?.showMaterial(false)
            self.sourceIcon.alpha = 1
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(changes)
            hasFinishedFade = true
            finishIfCollapsedAndFaded()
            return
        }
        let fade = UIViewPropertyAnimator(duration: 0.12, curve: .linear, animations: changes)
        circleFadeAnimator = fade
        fade.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.circleFadeAnimator = nil
            self.hasFinishedFade = true
            self.finishIfCollapsedAndFaded()
        }
        fade.startAnimation()
    }

    private func finishIfCollapsedAndFaded() {
        guard hasFinishedCollapse, hasFinishedFade else { return }
        finishDismissal()
    }

    private func stopAnimator() {
        guard let current = animator else { return }
        animator = nil
        guard current.state == .active else { return }
        // UIKit freezes every animated view property in its own coordinate
        // space. Replaying a glass backing layer's frame can move the panel.
        current.stopAnimation(false)
        current.finishAnimation(at: .current)
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
        circleFadeAnimator?.stopAnimation(true)
        circleFadeAnimator = nil
        collapseDisplayLink?.invalidate()
        collapseDisplayLink = nil
        collapsingCircle = nil
        guard view.superview != nil else { return }
        sourceView?.alpha = 1
        beginAppearanceTransition(false, animated: false)
        view.removeFromSuperview()
        endAppearanceTransition()
        details?.removeFromWindow()
        rootPanel?.remove()
        details = nil
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
        if let details { details.dismissSheet(animated: true) }
        else { close() }
    }
}
