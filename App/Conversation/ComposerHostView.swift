import UIKit

@MainActor
final class ComposerHostView: UIView, UITextViewDelegate {
    struct Configuration {
        let text: String
        let selection: ComposerSelection
        let state: ComposerPresentationState
        let collapseProgress: ComposerCollapseProgress
        let font: UIFont
        let showsPlus: Bool
        let primary: ComposerPrimaryAction
        let models: [ModelDescriptor]
        let selectedModelID: String
        let errorMessage: String?
        let onText: (String, ComposerSelection, Bool) -> Void
        let onFocus: (Bool) -> Void
        let onSend: () -> Void
        let onStop: () -> Void
        let onModel: (String) -> Void
    }

    private let surface = UIView()
    private let glass: UIVisualEffectView
    private let viewport = UIView()
    let editor = UITextView()
    let placeholder = UILabel()
    private let plus = UIButton(type: .system)
    private let primary = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let motion = ComposerMotionController()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var configuration: Configuration?
    private var currentState: ComposerPresentationState = .resting
    private var keyboardTiming: (duration: TimeInterval, options: UIView.AnimationOptions)?
    private var textRevision = 0
    private var measuredRevision = -1
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private var lastHostWidth: CGFloat = -1

    override init(frame: CGRect) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        glass = UIVisualEffectView(effect: effect)
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        keyboardLayoutGuide.usesBottomSafeArea = true
        keyboardLayoutGuide.followsUndockedKeyboard = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        widthConstraint = surface.widthAnchor.constraint(equalToConstant: 0)
        heightConstraint = surface.heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -12),
            widthConstraint, heightConstraint
        ])

        glass.isUserInteractionEnabled = false
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.addSubview(glass)

        viewport.clipsToBounds = true
        surface.addSubview(viewport)
        editor.delegate = self
        editor.backgroundColor = .clear
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.adjustsFontForContentSizeCategory = true
        editor.keyboardDismissMode = .interactive
        editor.isScrollEnabled = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.accessibilityIdentifier = "conversation-composer-input"
        viewport.addSubview(editor)
        placeholder.text = "输入消息"
        placeholder.textColor = .secondaryLabel
        placeholder.isUserInteractionEnabled = false
        viewport.addSubview(placeholder)

        for (button, symbol) in [(plus, "plus"), (primary, "arrow.up")] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = .white
            button.backgroundColor = .black
            button.cornerConfiguration = .capsule()
            surface.addSubview(button)
        }
        plus.accessibilityIdentifier = "conversation-composer-plus"
        plus.accessibilityLabel = "更多操作"
        plus.showsMenuAsPrimaryAction = true
        primary.accessibilityIdentifier = "conversation-composer-send"
        primary.accessibilityLabel = "发送"
        primary.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        errorLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        errorLabel.textColor = .systemRed
        errorLabel.accessibilityIdentifier = "composer-send-error"
        errorLabel.isUserInteractionEnabled = false
        addSubview(errorLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(surfaceTapped))
        tap.cancelsTouchesInView = false
        surface.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != lastHostWidth else { return }
        lastHostWidth = bounds.width
        render(animated: false)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let displayed = surface.layer.presentation()?.frame ?? surface.frame
        guard displayed.contains(point) else { return nil }
        let local = CGPoint(x: point.x - displayed.minX, y: point.y - displayed.minY)
        for button in [plus, primary] where !button.isHidden && button.isEnabled {
            if (button.layer.presentation()?.frame ?? button.frame).contains(local) { return button }
        }
        if (viewport.layer.presentation()?.frame ?? viewport.frame).contains(local) {
            return editor
        }
        return surface
    }

    var keyboardGap: CGFloat {
        keyboardLayoutGuide.layoutFrame.minY - surface.frame.maxY
    }

    var surfaceFrame: CGRect { surface.frame }

    func configure(_ next: Configuration) {
        let oldText = configuration?.text
        let oldFont = configuration?.font
        configuration = next
        editor.font = next.font
        placeholder.font = next.font
        if editor.markedTextRange == nil, editor.text != next.text {
            editor.text = next.text
        }
        if oldText != next.text { textRevision += 1 }
        if editor.markedTextRange == nil, !editor.isFirstResponder {
            let length = next.text.utf16.count
            let lower = min(length, max(0, next.selection.range.lowerBound))
            let upper = min(length, max(lower, next.selection.range.upperBound))
            let range = NSRange(location: lower, length: upper - lower)
            if editor.selectedRange != range { editor.selectedRange = range }
        }
        placeholder.isHidden = !next.text.isEmpty
        errorLabel.text = next.errorMessage
        plus.isHidden = !next.showsPlus
        plus.menu = makeMenu(next)
        switch next.primary {
        case .none:
            primary.isHidden = true
        case .send(let enabled):
            primary.isHidden = false
            primary.isEnabled = enabled
            primary.setImage(UIImage(systemName: "arrow.up"), for: .normal)
            primary.accessibilityLabel = "发送"
        case .stop(_, let enabled):
            primary.isHidden = false
            primary.isEnabled = enabled
            primary.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            primary.accessibilityLabel = "停止"
        }
        if currentState != next.state {
            currentState = next.state
            let token = motion.begin(next.state)
            render(animated: true, generation: token)
        } else if !motion.keepsEditingLayout || oldText != next.text || oldFont != next.font {
            render(animated: false)
        }
    }

    func requestFocus(_ focused: Bool) {
        if focused {
            if !editor.isFirstResponder { editor.becomeFirstResponder() }
        } else if editor.markedTextRange == nil, editor.isFirstResponder {
            editor.resignFirstResponder()
        }
    }

    private func render(animated: Bool, generation: Int? = nil) {
        guard let configuration, bounds.width > 0 else { return }
        let width = bounds.width
        let available = max(0, min(bounds.height, keyboardLayoutGuide.layoutFrame.minY))
        let editWidth = max(1, width - 2 * ComposerGeometry.edgeInset - 24)
        if measuredRevision != textRevision || abs(measuredWidth - editWidth) > 0.5 {
            measuredRevision = textRevision
            measuredWidth = editWidth
            let size = editor.sizeThatFits(CGSize(width: editWidth,
                                                  height: .greatestFiniteMagnitude))
            measuredHeight = max(configuration.font.lineHeight, size.height)
        }
        let state = configuration.state
        let layout = ComposerMorphGeometry.endpoint(
            state, containerWidth: width, availableHeight: available,
            measuredTextHeight: measuredHeight, lineHeight: configuration.font.lineHeight,
            collapseProgress: configuration.collapseProgress
        )
        let targetViewport = layout.textViewport
        let apply = {
            self.widthConstraint.constant = layout.size.width
            self.heightConstraint.constant = layout.size.height
            self.viewport.frame = targetViewport
            self.plus.frame = layout.plus.insetBy(dx: 8, dy: 8)
            self.primary.frame = layout.primary.insetBy(dx: 8, dy: 8)
            self.errorLabel.frame = CGRect(x: max(0, (width - layout.size.width) / 2),
                                           y: self.surface.frame.minY - 28,
                                           width: layout.size.width, height: 22)
            self.layoutIfNeeded()
        }
        let editorWidth = max(editWidth, targetViewport.width)
        editor.frame = CGRect(x: 0, y: 0, width: editorWidth,
                              height: max(measuredHeight, targetViewport.height))
        placeholder.frame = CGRect(x: 0, y: 0, width: editorWidth,
                                   height: configuration.font.lineHeight + 2)
        editor.isScrollEnabled = state == .editing && measuredHeight > targetViewport.height
        glass.cornerConfiguration = .corners(radius: .containerConcentric(
            minimum: layout.minimumCurvature
        ))
        surface.cornerConfiguration = glass.cornerConfiguration
        if animated, let generation {
            let timing = keyboardTiming
            keyboardTiming = nil
            let duration = UIAccessibility.isReduceMotionEnabled ? 0 : (timing?.duration ?? 0.25)
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: (timing?.options ?? [.curveEaseInOut]).union([.beginFromCurrentState,
                                                                    .allowUserInteraction]),
                animations: apply,
                completion: { finished in
                    guard self.motion.settle(generation, target: state, finished: finished) else { return }
                    self.editor.textContainer.maximumNumberOfLines = state == .editing ? 0 : 1
                    self.editor.textContainer.lineBreakMode = state == .editing
                        ? .byWordWrapping : .byTruncatingTail
                }
            )
        } else {
            apply()
            if !motion.keepsEditingLayout {
                editor.textContainer.maximumNumberOfLines = state == .editing ? 0 : 1
            }
        }
    }

    private func makeMenu(_ configuration: Configuration) -> UIMenu {
        func disabled(_ title: String, _ symbol: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: [.disabled]) { _ in }
        }
        let modelActions = configuration.models.map { model in
            UIAction(title: model.displayName,
                     state: model.id == configuration.selectedModelID ? .on : .off) { [weak self] _ in
                self?.configuration?.onModel(model.id)
            }
        }
        let modelMenu = UIMenu(title: "模型", image: UIImage(systemName: "cpu"),
                               children: modelActions.isEmpty ? [disabled("模型", "cpu")] : modelActions)
        return UIMenu(children: [
            disabled("添加图片", "photo"), disabled("添加文件", "doc"),
            disabled("插件", "puzzlepiece"), modelMenu,
            disabled("推理强度", "slider.horizontal.3")
        ])
    }

    @objc private func surfaceTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              recognizer.location(in: surface).y >= 0,
              configuration?.state != .editing else { return }
        configuration?.onFocus(true)
    }

    @objc private func primaryTapped() {
        switch configuration?.primary {
        case .send(let enabled) where enabled: configuration?.onSend()
        case .stop(_, let enabled) where enabled: configuration?.onStop()
        default: break
        }
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard window != nil, let info = notification.userInfo,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber,
              let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber else { return }
        keyboardTiming = (duration.doubleValue,
                          UIView.AnimationOptions(rawValue: UInt(curve.intValue) << 16))
        if motion.phase == .editing { render(animated: false) }
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        guard window != nil, currentState == .editing else { return }
        configuration?.onFocus(false)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { configuration?.onFocus(true) }
    func textViewDidEndEditing(_ textView: UITextView) { configuration?.onFocus(false) }
    func textViewDidChange(_ textView: UITextView) { reportEditor() }
    func textViewDidChangeSelection(_ textView: UITextView) { reportEditor() }

    private func reportEditor() {
        guard let configuration else { return }
        let range = editor.selectedRange
        configuration.onText(editor.text ?? "",
                             ComposerSelection(range: range.location..<(range.location + range.length)),
                             editor.markedTextRange != nil)
    }
}
