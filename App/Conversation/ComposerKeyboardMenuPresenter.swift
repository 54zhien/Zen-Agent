import SwiftUI
import UIKit

/// Owns the keyboard-sized surface without moving or replacing the retained editor.
/// Its overlay passes touches through above the sheet, including to the real + button.
@MainActor
final class ComposerKeyboardMenuPresenter: UIViewController {
    private let height: CGFloat
    private let presentation: ComposerActionMenuState
    private let onSelect: (ModelID) -> Void
    private let onClosing: (Bool) -> Void
    private let onDismiss: (ComposerKeyboardMenuPresenter, Bool) -> Void
    private let sheet = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let handle = UIView()
    private var actions: UIHostingController<ComposerActionMenuView>?
    private var models: UIHostingController<ComposerActionMenuView>?
    private var childGlass: UIVisualEffectView?
    private var installedSize = CGSize.zero
    private var awaitingKeyboard = true
    private var isClosing = false
    private var didDismiss = false
    private var restoresKeyboard = false

    init(height: CGFloat, presentation: ComposerActionMenuState,
         onSelect: @escaping (ModelID) -> Void, onClosing: @escaping (Bool) -> Void,
         onDismiss: @escaping (ComposerKeyboardMenuPresenter, Bool) -> Void) {
        self.height = height
        self.presentation = presentation
        self.onSelect = onSelect
        self.onClosing = onClosing
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let overlay = ComposerKeyboardMenuOverlay()
        overlay.sheet = sheet
        overlay.onEscape = { [weak self] in self?.close() }
        overlay.backgroundColor = .clear
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = overlay
        sheet.accessibilityIdentifier = "composer-keyboard-sheet"
        sheet.shouldGroupAccessibilityChildren = true
        sheet.accessibilityContainerType = .semanticGroup
        view.addSubview(sheet)
        sheet.addSubview(glass)
        glass.cornerConfiguration = .corners(radius: .fixed(34))
        glass.clipsToBounds = true
        handle.backgroundColor = .tertiaryLabel
        handle.layer.cornerRadius = 2.5
        handle.isUserInteractionEnabled = false
        handle.accessibilityElementsHidden = true
        glass.contentView.addSubview(handle)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivate),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func occupiedFrame(in window: UIWindow) -> CGRect? {
        guard viewIfLoaded?.window === window, !didDismiss else { return nil }
        return CGRect(x: window.bounds.minX, y: window.bounds.maxY - height,
                      width: window.bounds.width, height: height)
    }

    func show(in window: UIWindow, style: UIUserInterfaceStyle) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = style
        installedSize = window.bounds.size
        view.frame = window.bounds
        sheet.frame = CGRect(x: 0, y: view.bounds.maxY - height,
                             width: view.bounds.width, height: height)
        glass.frame = sheet.bounds.inset(by: UIEdgeInsets(top: 0, left: 6, bottom: 8, right: 6))
        handle.frame = CGRect(x: glass.bounds.midX - 22, y: 8, width: 44, height: 5)
        beginAppearanceTransition(true, animated: false)
        window.addSubview(view)
        actions = install(.actions, in: glass)
        endAppearanceTransition()
        sheet.transform = CGAffineTransform(translationX: 0, y: height)
    }

    /// The resign notification supplies the keyboard's real duration and curve.
    func reveal(duration: TimeInterval, options: UIView.AnimationOptions) {
        guard awaitingKeyboard, !isClosing else { return }
        awaitingKeyboard = false
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration,
                       delay: 0, options: options.union([.beginFromCurrentState, .allowUserInteraction])) {
            self.sheet.transform = .identity
        } completion: { [weak self] _ in
            guard let self, !self.isClosing else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: self.actions?.view)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A rotation invalidates the measured keyboard height. Release the old
        // reservation rather than carrying it into a differently sized viewport.
        if installedSize != .zero, view.bounds.size != installedSize { close(animated: false) }
    }

    private var contentFrame: CGRect {
        let bottom = max(8, (view.window?.safeAreaInsets.bottom ?? 0) - 8)
        return glass.bounds.inset(by: UIEdgeInsets(top: 24, left: 0, bottom: bottom, right: 0))
    }

    private func install(_ level: ComposerActionMenuLevel,
                         in material: UIVisualEffectView) -> UIHostingController<ComposerActionMenuView> {
        let content = UIHostingController(rootView: ComposerActionMenuView(
            level: level, presentation: presentation, maximumSize: contentFrame.size,
            onSelect: { [weak self] modelID in
                guard let self, !self.isClosing else { return }
                WorkspaceHaptics.shared.play(.control)
                self.onSelect(modelID)
                self.close()
            }, onOpenModels: { [weak self] _ in self?.openDetails(.models) },
            onReturn: { [weak self] in self?.returnToActions() }, keyboardSheet: true,
            onOpenThinking: { [weak self] _ in self?.openDetails(.thinking) }))
        content.safeAreaRegions = []
        content.view.backgroundColor = .clear
        addChild(content)
        material.contentView.addSubview(content.view)
        content.view.frame = contentFrame
        content.didMove(toParent: self)
        return content
    }

    private func openDetails(_ level: ComposerActionMenuLevel) {
        guard !isClosing, models == nil, level != .models || !presentation.models.isEmpty else { return }
        WorkspaceHaptics.shared.play(.control)
        let child = UIVisualEffectView(effect: nil)
        child.cornerConfiguration = glass.cornerConfiguration
        child.clipsToBounds = true
        child.frame = glass.bounds
        glass.contentView.addSubview(child)
        childGlass = child
        models = install(level, in: child)
        actions?.view.isUserInteractionEnabled = false
        actions?.view.accessibilityElementsHidden = true
        child.transform = CGAffineTransform(translationX: 0, y: 24)
        models?.view.alpha = 0
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            child.effect = UIGlassEffect(style: .regular)
            child.transform = .identity
            self.models?.view.alpha = 1
        } completion: { [weak self] finished in
            guard finished, let self, !self.isClosing else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: self.models?.view)
        }
    }

    private func returnToActions() {
        guard !isClosing, let child = childGlass, let content = models,
              content.view.isUserInteractionEnabled else { return }
        WorkspaceHaptics.shared.play(.control)
        content.view.isUserInteractionEnabled = false
        content.view.accessibilityElementsHidden = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            child.effect = nil
            child.transform = CGAffineTransform(translationX: 0, y: 24)
            content.view.alpha = 0
        } completion: { [weak self] _ in
            guard let self, self.models === content else { return }
            self.remove(content)
            child.removeFromSuperview()
            self.models = nil
            self.childGlass = nil
            self.actions?.view.isUserInteractionEnabled = true
            self.actions?.view.accessibilityElementsHidden = false
            UIAccessibility.post(notification: .layoutChanged, argument: self.actions?.view)
        }
    }

    func close(restoringKeyboard: Bool = false, animated: Bool = true) {
        guard !didDismiss else { return }
        restoresKeyboard = restoresKeyboard || restoringKeyboard
        if isClosing {
            if !animated { finishClose() }
            return
        }
        isClosing = true
        onClosing(animated)
        guard animated, !UIAccessibility.isReduceMotionEnabled else { finishClose(); return }
        UIView.animate(withDuration: 0.25, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.sheet.transform = CGAffineTransform(translationX: 0, y: self.height)
        } completion: { [weak self] _ in self?.finishClose() }
    }

    private func finishClose() {
        guard !didDismiss else { return }
        didDismiss = true
        sheet.layer.removeAllAnimations()
        if let models { remove(models) }
        if let actions { remove(actions) }
        models = nil
        actions = nil
        childGlass?.removeFromSuperview()
        childGlass = nil
        beginAppearanceTransition(false, animated: false)
        view.removeFromSuperview()
        endAppearanceTransition()
        onDismiss(self, restoresKeyboard)
    }

    private func remove(_ content: UIViewController) {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
    }

    @objc private func deactivate() { close(animated: false) }
}

@MainActor
private final class ComposerKeyboardMenuOverlay: UIView {
    weak var sheet: UIView?
    var onEscape: (() -> Void)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let sheet else { return false }
        return sheet.point(inside: convert(point, to: sheet), with: event)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }
}
