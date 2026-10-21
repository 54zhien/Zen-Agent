import SwiftUI
import UIKit

/// Owns only the app-side sheet. The session coordinates the real keyboard and
/// keeps the input region reserved independently of this sheet's visible position.
@MainActor
final class ComposerKeyboardMenuPresenter: UIViewController {
    private let height: CGFloat
    private let presentation: ComposerActionMenuState
    private let onSelect: (ModelID) -> Void
    var onClose: ((Bool, Bool) -> Void)?
    var onInvalidated: (() -> Void)?
    private let sheet = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let handle = UIView()
    private var actions: UIHostingController<ComposerActionMenuView>?
    private var details: ComposerMenuDetailPresenter?
    private var installedSize = CGSize.zero
    private weak var sourceWindow: UIWindow?
    private var cornerRadius: CGFloat = 0
    private var laidOutBounds = CGRect.null
    private var isClosing = false
    private var didDismiss = false
    private var animator: UIViewPropertyAnimator?

    var inputDescentTarget: (sheet: UIView, travel: CGFloat) {
        details?.inputDescentTarget ?? (sheet, height)
    }

    init(height: CGFloat, presentation: ComposerActionMenuState,
         onSelect: @escaping (ModelID) -> Void) {
        self.height = height
        self.presentation = presentation
        presentation.isSuspended = false
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let input = ComposerMenuOverlayView()
        input.onEscape = { [weak self] in self?.close() }
        input.onLayout = { [weak self] in self?.layoutInput() }
        input.content = sheet
        input.backgroundColor = .clear
        input.isOpaque = false
        input.clipsToBounds = true
        view = input
        sheet.accessibilityIdentifier = "composer-keyboard-sheet"
        sheet.shouldGroupAccessibilityChildren = true
        sheet.accessibilityContainerType = .semanticGroup
        view.addSubview(sheet)
        sheet.addSubview(glass)
        glass.clipsToBounds = true
        handle.backgroundColor = .tertiaryLabel
        handle.layer.cornerRadius = 2.5
        handle.isUserInteractionEnabled = false
        handle.accessibilityElementsHidden = true
        glass.contentView.addSubview(handle)
    }

    func prepare(in window: UIWindow, style: UIUserInterfaceStyle, screenRadius: CGFloat) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = style
        view.overrideUserInterfaceStyle = style
        sourceWindow = window
        installedSize = window.bounds.size
        // The glass is inset equally from the display's side and bottom edges.
        cornerRadius = max(0, screenRadius - 6)
        presentation.activeLevel = .actions
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layoutInput()
        let content = UIHostingController(rootView: menuView())
        actions = content
        content.safeAreaRegions = []
        content.view.backgroundColor = .clear
        addChild(content)
        glass.contentView.addSubview(content.view)
        content.view.frame = glass.bounds
        content.didMove(toParent: self)
    }

    private func layoutInput() {
        guard !isClosing, !didDismiss else { return }
        if let sourceWindow, sourceWindow.bounds.size != installedSize {
            Task { @MainActor [weak self] in self?.onInvalidated?() }
            return
        }
        guard view.bounds != laidOutBounds else { return }
        laidOutBounds = view.bounds
        // Bounds/center are safe while a presentation transform is active.
        sheet.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        sheet.center = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - height / 2)
        glass.frame = sheet.bounds.inset(by: UIEdgeInsets(top: 0, left: 6, bottom: 6, right: 6))
        glass.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        handle.frame = CGRect(x: glass.bounds.midX - 22, y: 8, width: 44, height: 5)
        if let actions {
            actions.view.frame = glass.bounds
            actions.rootView = menuView()
        }
    }

    private func menuView() -> ComposerActionMenuView {
        ComposerActionMenuView(presentation: presentation, maximumSize: glass.bounds.size,
            onOpen: { [weak self] level in self?.openDetails(level) },
            keyboardSheet: true, cornerRadius: cornerRadius)
    }

    private func openDetails(_ level: ComposerActionMenuLevel) {
        guard !isClosing, details == nil, let window = sourceWindow else { return }
        WorkspaceHaptics.shared.play(.control)
        let detail = ComposerMenuDetailPresenter(level: level, presentation: presentation, height: height, compactThinking: true,
            onSelect: onSelect,
            onReturn: { [weak self] animator in self?.revealActions(using: animator) },
            onDismiss: { [weak self] in
                guard let self, !self.isClosing else { return }
                self.details = nil
                self.presentation.activeLevel = .actions
                self.sheet.isHidden = false
                self.sheet.accessibilityElementsHidden = false
                UIAccessibility.post(notification: .layoutChanged, argument: self.actions?.view)
            })
        details = detail
        sheet.isHidden = true
        sheet.accessibilityElementsHidden = true
        detail.show(in: window, style: overrideUserInterfaceStyle, cornerRadius: cornerRadius + 6)
    }

    private func revealActions(using animator: UIViewPropertyAnimator?) {
        guard !isClosing, !didDismiss else { return }
        UIView.performWithoutAnimation {
            self.glass.effect = nil
            self.actions?.view.alpha = 0
            self.actions?.view.transform = CGAffineTransform(translationX: 0, y: 14)
            self.handle.alpha = 0
            self.sheet.isHidden = false
        }
        let reveal = { [weak self] in
            guard let self else { return }
            self.glass.effect = UIGlassEffect(style: .regular)
            self.actions?.view.alpha = 1
            self.actions?.view.transform = .identity
            self.handle.alpha = 1
        }
        if let animator { animator.addAnimations(reveal) } else { reveal() }
    }

    func reveal(in window: UIWindow, animated: Bool = true, completion: @escaping () -> Void) {
        guard !didDismiss else { return }
        window.addSubview(view)
        view.layoutIfNeeded()
        if !animated {
            sheet.transform = .identity
            completion()
            return
        }
        sheet.transform = CGAffineTransform(translationX: 0, y: height)
        let animation = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.28,
                                               curve: .easeOut) {
            self.sheet.transform = .identity
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, !self.isClosing, !self.didDismiss, position == .end else { return }
            self.animator = nil
            UIAccessibility.post(notification: .layoutChanged, argument: self.actions?.view)
            completion()
        }
        animation.startAnimation()
    }

    func close(restoringKeyboard: Bool = true, animated: Bool = true) {
        onClose?(restoringKeyboard, animated)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        guard !didDismiss else { completion(); return }
        isClosing = true
        if let details {
            sheet.isHidden = true
            details.dismissForInputClosure(animated: animated) { [weak self] in
                guard let self, !self.didDismiss else { return }
                self.removeFromWindow()
                completion()
            }
            return
        }
        sheet.isHidden = false
        if let animator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            self.animator = nil
        }
        guard animated, view.superview != nil, !UIAccessibility.isReduceMotionEnabled else {
            removeFromWindow()
            completion()
            return
        }
        let animation = UIViewPropertyAnimator(duration: 0.23, curve: .easeIn) {
            self.sheet.transform = CGAffineTransform(translationX: 0, y: self.height)
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, !self.didDismiss, position == .end else { return }
            self.animator = nil
            self.removeFromWindow()
            completion()
        }
        animation.startAnimation()
    }

    func suspend() {
        presentation.suspensionRevision &+= 1
        presentation.isSuspended = true
        presentation.previewThinkingEffort = nil
        view.isUserInteractionEnabled = false
        if let animator, animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
        details?.suspend()
    }

    func resume() {
        presentation.isSuspended = false
        view.isUserInteractionEnabled = true
        details?.resume()
    }

    func removeFromWindow() {
        guard !didDismiss else { return }
        didDismiss = true
        if animator?.state == .active { animator?.stopAnimation(true) }
        animator = nil
        view.removeFromSuperview()
        details?.removeFromWindow()
        if let actions { remove(actions) }
        details = nil
        actions = nil
    }

    private func remove(_ content: UIViewController) {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
    }
}

@MainActor
private final class ComposerMenuOverlayView: UIView {
    weak var content: UIView?
    var onEscape: (() -> Void)?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let content, !isHidden, alpha > 0 else { return nil }
        return content.hitTest(convert(point, to: content), with: event)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }
}
