import SwiftUI
import UIKit

/// A custom input view owned by the retained editor, using UIKit keyboard avoidance.
/// Switching input views never resigns the editor or adds a second window overlay.
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
    private weak var sourceWindow: UIWindow?
    private var cornerRadius: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var laidOutBounds = CGRect.null
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
        let input = ComposerMenuInputView(height: height)
        input.onEscape = { [weak self] in self?.close() }
        input.onLayout = { [weak self] in self?.layoutInput() }
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
        NotificationCenter.default.addObserver(self, selector: #selector(deactivate),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func prepare(in window: UIWindow, style: UIUserInterfaceStyle, screenRadius: CGFloat) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = style
        view.overrideUserInterfaceStyle = style
        sourceWindow = window
        installedSize = window.bounds.size
        bottomInset = window.safeAreaInsets.bottom
        // The glass is inset equally from the display's side and bottom edges.
        cornerRadius = max(0, screenRadius - 6)
        presentation.activeLevel = .actions
        view.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: height)
        layoutInput()
        actions = install(.actions, in: glass)
    }

    private func layoutInput() {
        guard !isClosing, !didDismiss else { return }
        if let sourceWindow, sourceWindow.bounds.size != installedSize {
            // A rotated window needs the system keyboard's new height. Defer the
            // input-view replacement until outside UIKit's current layout pass.
            Task { @MainActor [weak self] in self?.close(animated: false) }
            return
        }
        guard view.bounds != laidOutBounds else { return }
        laidOutBounds = view.bounds
        sheet.frame = view.bounds
        glass.frame = sheet.bounds.inset(by: UIEdgeInsets(top: 0, left: 6, bottom: 6, right: 6))
        glass.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        handle.frame = CGRect(x: glass.bounds.midX - 22, y: 8, width: 44, height: 5)
        childGlass?.frame = glass.bounds
        if let actions {
            actions.view.frame = contentFrame(for: .actions)
            actions.rootView = menuView(.actions)
        }
        if let models {
            models.view.frame = contentFrame(for: presentation.activeLevel)
            models.rootView = menuView(presentation.activeLevel)
        }
    }

    private func contentFrame(for level: ComposerActionMenuLevel) -> CGRect {
        if level == .actions { return glass.bounds }
        return glass.bounds.inset(by: UIEdgeInsets(top: 24, left: 0,
            bottom: max(8, bottomInset - 6), right: 0))
    }

    private func menuView(_ level: ComposerActionMenuLevel) -> ComposerActionMenuView {
        ComposerActionMenuView(
            level: level, presentation: presentation, maximumSize: contentFrame(for: level).size,
            onSelect: { [weak self] modelID in
                guard let self, !self.isClosing else { return }
                WorkspaceHaptics.shared.play(.control)
                self.onSelect(modelID)
                self.close()
            }, onOpenModels: { [weak self] _ in self?.openDetails(.models) },
            onReturn: { [weak self] in self?.returnToActions() }, keyboardSheet: true,
            sheetCornerRadius: cornerRadius,
            onOpenThinking: { [weak self] _ in self?.openDetails(.thinking) })
    }

    private func install(_ level: ComposerActionMenuLevel,
                         in material: UIVisualEffectView) -> UIHostingController<ComposerActionMenuView> {
        let content = UIHostingController(rootView: menuView(level))
        content.safeAreaRegions = []
        content.view.backgroundColor = .clear
        addChild(content)
        material.contentView.addSubview(content.view)
        content.view.frame = contentFrame(for: level)
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
        presentation.activeLevel = level
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
            self.presentation.activeLevel = .actions
            self.actions?.view.isUserInteractionEnabled = true
            self.actions?.view.accessibilityElementsHidden = false
            UIAccessibility.post(notification: .layoutChanged, argument: self.actions?.view)
        }
    }

    func close(restoringKeyboard: Bool = true, animated: Bool = true) {
        guard !didDismiss else { return }
        isClosing = true
        didDismiss = true
        restoresKeyboard = restoringKeyboard
        onClosing(animated)
        // UIKit replaces the input view directly. A separate slide-out would
        // leave an empty input region before the keyboard returns.
        onDismiss(self, restoresKeyboard)
        if let models { remove(models) }
        if let actions { remove(actions) }
        models = nil
        actions = nil
        childGlass?.removeFromSuperview()
        childGlass = nil
    }

    private func remove(_ content: UIViewController) {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
    }

    @objc private func deactivate() { close(restoringKeyboard: false, animated: false) }
}

@MainActor
private final class ComposerMenuInputView: UIInputView {
    private let occupiedHeight: CGFloat
    var onEscape: (() -> Void)?
    var onLayout: (() -> Void)?

    init(height: CGFloat) {
        occupiedHeight = height
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: occupiedHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: occupiedHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: occupiedHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }
}
