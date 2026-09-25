import SwiftUI
import UIKit

@MainActor
final class ComposerHostView: UIView, UITextViewDelegate, UIDropInteractionDelegate,
                              UIGestureRecognizerDelegate {
    struct Configuration {
        let text: String
        let selection: ComposerSelection
        let state: ComposerPresentationState
        let collapseProgress: ComposerCollapseProgress
        let font: UIFont
        let showsPlus: Bool
        let primary: ComposerPrimaryAction
        let models: [ModelDescriptor]
        let selectedModelID: ModelID
        let errorMessage: String?
        let references: [QuoteReference]
        let onRemoveQuote: (String) -> Void
        let onAcceptQuote: (QuoteReference) -> Void
        let onQuotePhase: (ComposerQuoteDragPhase) -> Void
        let onText: (String, ComposerSelection, Bool) -> Void
        let onFocus: (Bool) -> Void
        let onSend: () -> Void
        let onStop: () -> Void
        let onModel: (ModelID) -> Void
        let onHeightChanged: (CGFloat) -> Void
    }

    private let surface = UIView()
    private let glass: UIVisualEffectView
    private let viewport = UIView()
    let editor = UITextView()
    let placeholder = UILabel()
    private var placeholderHeightConstraint: NSLayoutConstraint!
    private let plus = UIButton(type: .system)
    private let primary = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let geometryProbe = UIView()
    private var shelfController: UIHostingController<QuoteShelfView>?
    private var shelfHeight: CGFloat = 44
    private var quotePhase: ComposerQuoteDragPhase = .idle
    private let motion = ComposerMotionController()
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var configuration: Configuration?
    private var currentState: ComposerPresentationState = .resting
    private var keyboardTiming: (duration: TimeInterval, options: UIView.AnimationOptions)?
    private var textRevision = 0
    private var measuredRevision = -1
    private var measuredWidth: CGFloat = -1
    private var measuredFont: UIFont?
    private var measuredHeight: CGFloat = 0
    private var lastHostWidth: CGFloat = -1
    private var lastReportedClearance: CGFloat = -1
    private weak var textCarrier: UIView?

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
        bottomConstraint = surface.bottomAnchor.constraint(
            equalTo: keyboardLayoutGuide.topAnchor, constant: -12
        )
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomConstraint,
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
        editor.accessibilityLabel = "输入消息"
        viewport.addSubview(editor)
        placeholder.text = "输入消息"
        placeholder.textColor = .secondaryLabel
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(placeholder)
        placeholderHeightConstraint = placeholder.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            placeholder.firstBaselineAnchor.constraint(equalTo: editor.firstBaselineAnchor),
            placeholder.widthAnchor.constraint(equalTo: editor.widthAnchor),
            placeholderHeightConstraint
        ])

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
        surface.addSubview(errorLabel)
        addInteraction(UIDropInteraction(delegate: self))
        if ProcessInfo.processInfo.environment["ZEN_COMPOSER_GEOMETRY_TEST"] == "1" {
            geometryProbe.isAccessibilityElement = true
            geometryProbe.isUserInteractionEnabled = false
            geometryProbe.accessibilityIdentifier = "composer-geometry-probe"
            addSubview(geometryProbe)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(surfaceTapped))
        tap.delegate = self
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let shelfController else { return }
        if window != nil {
            attachShelf(shelfController)
        } else if shelfController.parent != nil {
            shelfController.willMove(toParent: nil)
            shelfController.removeFromParent()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometryProbe()
        guard bounds.width > 0, bounds.width != lastHostWidth else { return }
        lastHostWidth = bounds.width
        render(animated: false)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let displayed = surface.layer.presentation()?.frame ?? surface.frame
        let shelfFrame = CGRect(x: displayed.minX, y: displayed.minY - shelfHeight,
                                width: displayed.width, height: shelfHeight)
        if !shelfViewIsHidden, shelfFrame.contains(point), let shelf = shelfController?.view {
            let local = CGPoint(x: point.x - shelfFrame.minX, y: point.y - shelfFrame.minY)
            return shelf.hitTest(local, with: event) ?? shelf
        }
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

    private var shelfViewIsHidden: Bool { shelfController?.view.isHidden ?? true }

    func configure(_ next: Configuration) {
        let oldText = configuration?.text
        let oldFont = configuration?.font
        configuration = next
        editor.font = next.font
        placeholder.font = next.font
        let updatePolicy = ComposerTextViewUpdatePolicy.resolve(
            markedTextPresent: editor.markedTextRange != nil
        )
        if updatePolicy.writesText, editor.text != next.text {
            editor.text = next.text
        }
        if oldText != next.text { textRevision += 1 }
        if updatePolicy.writesSelection, !editor.isFirstResponder {
            let length = next.text.utf16.count
            let lower = min(length, max(0, next.selection.range.lowerBound))
            let upper = min(length, max(lower, next.selection.range.upperBound))
            let range = NSRange(location: lower, length: upper - lower)
            if editor.selectedRange != range { editor.selectedRange = range }
        }
        placeholder.isHidden = !next.text.isEmpty
        errorLabel.text = next.errorMessage
        updateShelf(next)
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
            if next.state == .editing {
                // The viewport still clips the resting first line; prepare multiline layout
                // before it widens so the visible text keeps one local origin.
                editor.textContainer.maximumNumberOfLines = 0
                editor.textContainer.lineBreakMode = .byWordWrapping
            }
            if bounds.width > 0 {
                let token = motion.begin(next.state)
                render(animated: true, generation: token)
            } else {
                motion.reset(to: next.state)
            }
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
        if measuredRevision != textRevision || abs(measuredWidth - editWidth) > 0.5
            || measuredFont != configuration.font {
            measuredRevision = textRevision
            measuredWidth = editWidth
            measuredFont = configuration.font
            measuredHeight = ComposerTextMeasurement.height(
                text: configuration.text, width: editWidth, font: configuration.font
            )
        }
        let state = configuration.state
        let layout = ComposerMorphGeometry.endpoint(
            state, containerWidth: width, availableHeight: available,
            measuredTextHeight: measuredHeight, lineHeight: configuration.font.lineHeight,
            collapseProgress: configuration.collapseProgress
        )
        let editingEndpoint = ComposerMorphGeometry.endpoint(
            .editing, containerWidth: width, availableHeight: available,
            measuredTextHeight: measuredHeight, lineHeight: configuration.font.lineHeight,
            collapseProgress: configuration.collapseProgress
        )
        let targetViewport = layout.textViewport
        let clearance = layout.size.height + 12
            + ((configuration.references.isEmpty || state == .compact) ? 0 : shelfHeight)
        if abs(clearance - lastReportedClearance) > 0.5 {
            lastReportedClearance = clearance
            Task { @MainActor [weak self] in
                self?.configuration?.onHeightChanged(clearance)
            }
        }
        let apply = {
            self.widthConstraint.constant = layout.size.width
            self.heightConstraint.constant = layout.size.height
            self.bottomConstraint.constant = -layout.bottomSpacing
            self.viewport.frame = targetViewport
            self.plus.frame = layout.plus.insetBy(dx: 8, dy: 8)
            self.primary.frame = layout.primary.insetBy(dx: 8, dy: 8)
            self.errorLabel.frame = CGRect(x: 0, y: -28,
                                           width: layout.size.width, height: 22)
            self.shelfController?.view.frame = CGRect(x: 0, y: -self.shelfHeight,
                                                      width: layout.size.width,
                                                      height: self.shelfHeight)
            self.layoutIfNeeded()
            self.updateGeometryProbe()
        }
        let editorWidth = max(editWidth, targetViewport.width)
        editor.frame = CGRect(x: 0, y: 0, width: editorWidth,
                              height: max(1, editingEndpoint.textViewport.height))
        placeholderHeightConstraint.constant = configuration.font.lineHeight + 2
        if state == .editing {
            editor.isScrollEnabled = measuredHeight > editingEndpoint.textViewport.height
        }
        glass.cornerConfiguration = .corners(radius: .containerConcentric(
            minimum: layout.minimumCurvature
        ))
        surface.cornerConfiguration = glass.cornerConfiguration
        if animated, let generation {
            textCarrier?.removeFromSuperview()
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
                    self.finishTextLayout(state)
                }
            )
        } else {
            apply()
            if !motion.keepsEditingLayout {
                finishTextLayout(state)
            }
        }
    }

    private func finishTextLayout(_ state: ComposerPresentationState) {
        let needsLocalHandoff = state != .editing && editor.contentOffset.y > 1
        let carrier = needsLocalHandoff ? viewport.snapshotView(afterScreenUpdates: false) : nil
        if let carrier {
            carrier.frame = viewport.bounds
            viewport.addSubview(carrier)
            textCarrier = carrier
        }
        editor.textContainer.maximumNumberOfLines = state == .editing ? 0 : 1
        editor.textContainer.lineBreakMode = state == .editing
            ? .byWordWrapping : .byTruncatingTail
        if state != .editing {
            editor.isScrollEnabled = false
            editor.contentOffset = .zero
            editor.frame.size.height = max(1, viewport.bounds.height)
        }
        if let carrier {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12,
                           animations: { carrier.alpha = 0 },
                           completion: { [weak carrier] _ in carrier?.removeFromSuperview() })
        }
    }

    private func updateGeometryProbe() {
        guard geometryProbe.superview != nil, let window else { return }
        geometryProbe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rootBottom = convert(CGPoint(x: 0, y: bounds.maxY), to: window).y
        let guideTop = convert(CGPoint(x: 0, y: keyboardLayoutGuide.layoutFrame.minY),
                               to: window).y
        let surfaceBottom = surface.convert(CGPoint(x: 0, y: surface.bounds.maxY),
                                            to: window).y
        geometryProbe.accessibilityValue = "root=\(rootBottom);guide=\(guideTop);surface=\(surfaceBottom)"
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

    private func updateShelf(_ configuration: Configuration) {
        if shelfController == nil {
            let controller = UIHostingController(rootView: QuoteShelfView(entries: []))
            controller.view.backgroundColor = .clear
            controller.safeAreaRegions = []
            shelfController = controller
            surface.addSubview(controller.view)
            attachShelf(controller)
        }
        shelfController?.rootView = QuoteShelfView(
            entries: configuration.references.map(QuoteShelfEntry.init),
            onRemove: { [weak self] id in self?.configuration?.onRemoveQuote(id) },
            onMeasuredHeight: { [weak self] height in
                guard let self, height.isFinite, height > 0,
                      abs(self.shelfHeight - height) > 0.5 else { return }
                self.shelfHeight = height
                self.shelfController?.view.frame.origin.y = -height
                self.shelfController?.view.frame.size.height = height
                if !self.shelfViewIsHidden {
                    self.configuration?.onHeightChanged(self.surface.frame.height + 12 + height)
                }
            }
        )
        shelfController?.view.isHidden = configuration.references.isEmpty
            || configuration.state == .compact
    }

    private func attachShelf(_ controller: UIHostingController<QuoteShelfView>) {
        guard controller.parent == nil else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let parent = current as? UIViewController {
                parent.addChild(controller)
                controller.didMove(toParent: parent)
                return
            }
            responder = current.next
        }
    }

    @objc private func surfaceTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              recognizer.location(in: surface).y >= 0,
              configuration?.state != .editing else { return }
        configuration?.onFocus(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        touch.view === surface
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

    func dropInteraction(_ interaction: UIDropInteraction,
                         canHandle session: any UIDropSession) -> Bool {
        session.localDragSession != nil
            && session.items.contains { $0.localObject is InternalQuoteDrag }
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidEnter session: any UIDropSession) {
        updateQuotePhase(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard dropInteraction(interaction, canHandle: session) else {
            return UIDropProposal(operation: .forbidden)
        }
        updateQuotePhase(session)
        return UIDropProposal(operation: quotePhase == .overDropZone ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidExit session: any UIDropSession) {
        setQuotePhase(.active)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         performDrop session: any UIDropSession) {
        defer { setQuotePhase(.idle) }
        guard let configuration,
              dropFrame.contains(session.location(in: self)) else { return }
        for item in session.items {
            if let reference = QuoteDragBridge.acceptedReference(
                localObject: item.localObject,
                hasLocalDragSession: session.localDragSession != nil,
                existing: configuration.references
            ) {
                configuration.onAcceptQuote(reference)
                break
            }
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidEnd session: any UIDropSession) {
        setQuotePhase(.idle)
    }

    private var dropFrame: CGRect {
        let displayed = surface.layer.presentation()?.frame ?? surface.frame
        let shelf = shelfViewIsHidden ? .zero : CGRect(
            x: displayed.minX, y: displayed.minY - shelfHeight,
            width: displayed.width, height: shelfHeight
        )
        return shelf.isEmpty ? displayed : displayed.union(shelf)
    }

    private func updateQuotePhase(_ session: any UIDropSession) {
        setQuotePhase(dropFrame.contains(session.location(in: self)) ? .overDropZone : .active)
    }

    private func setQuotePhase(_ phase: ComposerQuoteDragPhase) {
        guard phase != quotePhase else { return }
        quotePhase = phase
        configuration?.onQuotePhase(phase)
    }
}
