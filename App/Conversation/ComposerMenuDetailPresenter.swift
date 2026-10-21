import SwiftUI
import UIKit

/// Shared bottom detail sheet. Dismissal returns to its retained primary menu;
/// only that menu's owner can end the input-area session and restore the keyboard.
@MainActor
final class ComposerMenuDetailPresenter: UIViewController {
    private let level: ComposerActionMenuLevel
    private let presentation: ComposerActionMenuState
    private let height: CGFloat
    private let onSelect: (ModelID) -> Void
    private let onDismiss: () -> Void
    private let outside = UIControl()
    private let backdrop = UIVisualEffectView(effect: nil)
    private let sheet = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let handle = UIView()
    private var content: UIHostingController<ComposerMenuDetailView>?
    private var animator: UIViewPropertyAnimator?
    private var closing = false
    private var removed = false
    private var installedSize = CGSize.zero

    init(level: ComposerActionMenuLevel, presentation: ComposerActionMenuState, height: CGFloat,
         onSelect: @escaping (ModelID) -> Void, onDismiss: @escaping () -> Void) {
        self.level = level
        self.presentation = presentation
        self.height = height
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let overlay = ComposerDetailOverlay()
        overlay.onEscape = { [weak self] in self?.dismissSheet(animated: true) }
        overlay.backgroundColor = .clear
        overlay.accessibilityViewIsModal = true
        view = overlay
        view.addSubview(outside)
        outside.accessibilityElementsHidden = true
        outside.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backdrop.isUserInteractionEnabled = false
        view.addSubview(backdrop)
        sheet.clipsToBounds = true
        view.addSubview(sheet)
        handle.backgroundColor = .tertiaryLabel
        handle.layer.cornerRadius = 2.5
        handle.isUserInteractionEnabled = false
        sheet.contentView.addSubview(handle)
        // Restrict downward dismissal to the handle so a vertical effort drag
        // cannot accidentally close its sheet.
        let handleTarget = UIView()
        handleTarget.frame = CGRect(x: 0, y: 0, width: 200, height: 20)
        handleTarget.autoresizingMask = [.flexibleWidth]
        sheet.contentView.addSubview(handleTarget)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(closeTapped))
        swipe.direction = .down
        handleTarget.addGestureRecognizer(swipe)
    }

    func show(in window: UIWindow, style: UIUserInterfaceStyle, cornerRadius: CGFloat) {
        loadViewIfNeeded()
        installedSize = window.bounds.size
        overrideUserInterfaceStyle = style
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outside.frame = view.bounds
        let actualHeight = min(height, window.bounds.height - window.safeAreaInsets.top - 12)
        sheet.frame = CGRect(x: 6, y: view.bounds.maxY - actualHeight,
                             width: view.bounds.width - 12, height: actualHeight - 6)
        sheet.cornerConfiguration = .corners(radius: .fixed(max(0, cornerRadius - 6)))
        handle.frame = CGRect(x: sheet.bounds.midX - 22, y: 8, width: 44, height: 5)
        backdrop.frame = CGRect(x: 0, y: max(0, sheet.frame.minY - 64), width: view.bounds.width,
                                height: actualHeight + 64)
        let mask = CAGradientLayer()
        mask.frame = backdrop.bounds
        mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        mask.locations = [0, 0.22, 1]
        backdrop.layer.mask = mask
        let content = UIHostingController(rootView: ComposerMenuDetailView(
            level: level, presentation: presentation,
            onSelect: { [weak self] id in
                guard let self, !self.closing else { return }
                WorkspaceHaptics.shared.play(.control)
                self.onSelect(id)
                self.dismissSheet(animated: true)
            }, onClose: { [weak self] in self?.dismissSheet(animated: true) }))
        self.content = content
        content.safeAreaRegions = []
        content.view.backgroundColor = .clear
        addChild(content)
        sheet.contentView.addSubview(content.view)
        content.view.frame = sheet.bounds.inset(by: UIEdgeInsets(top: 20, left: 0,
            bottom: max(12, window.safeAreaInsets.bottom - 6), right: 0))
        content.didMove(toParent: self)
        presentation.activeLevel = level
        window.addSubview(view)
        view.layoutIfNeeded()
        sheet.transform = CGAffineTransform(translationX: 0, y: actualHeight)
        let animation = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.28,
                                                curve: .easeOut) {
            self.sheet.transform = .identity
            self.outside.backgroundColor = UIColor.black.withAlphaComponent(0.08)
            if self.level == .thinking { self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, !self.closing, position == .end else { return }
            self.animator = nil
            UIAccessibility.post(notification: .screenChanged, argument: content.view)
        }
        animation.startAnimation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if installedSize != .zero, view.bounds.size != installedSize, !closing {
            dismissSheet(animated: false)
        }
    }

    @objc private func closeTapped() { dismissSheet(animated: true) }

    func dismissSheet(animated: Bool) {
        guard !closing, !removed else { return }
        closing = true
        content?.view.isUserInteractionEnabled = false
        if let animator, animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { finish(); return }
        let animation = UIViewPropertyAnimator(duration: 0.23, curve: .easeIn) {
            self.sheet.transform = CGAffineTransform(translationX: 0, y: self.height)
            self.backdrop.effect = nil
            self.outside.backgroundColor = .clear
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            if position == .end { self?.finish() }
        }
        animation.startAnimation()
    }

    private func finish() {
        guard !removed else { return }
        removeFromWindow()
        presentation.activeLevel = .actions
        onDismiss()
    }

    func removeFromWindow() {
        guard !removed else { return }
        removed = true
        closing = true
        if animator?.state == .active { animator?.stopAnimation(true) }
        animator = nil
        content?.willMove(toParent: nil)
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        content = nil
        viewIfLoaded?.removeFromSuperview()
    }
}

private final class ComposerDetailOverlay: UIView {
    var onEscape: (() -> Void)?
    override func accessibilityPerformEscape() -> Bool { onEscape?(); return true }
}
