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
        let selectedModelID: ModelID?
        let errorMessage: String?
        let references: [QuoteReference]
        let onRemoveQuote: (String) -> Void
        let onAcceptQuote: (QuoteReference) -> Void
        let onQuotePhase: (ComposerQuoteDragPhase) -> Void
        let onText: (String, ComposerSelection, Bool) -> Void
        let onFocus: (Bool) -> Void
        var onKeyboardWillChange: () -> Void = {}
        let onSend: () -> Void
        let onStop: () -> Void
        let onModel: (ModelID) -> Void
        let onHeightChanged: (CGFloat) -> Void
        var liftInteraction: ComposerLiftInteraction.Configuration? = nil
    }

    private let surface = UIView()
    private let glass: UIVisualEffectView
    private let viewport = UIView()
    let editor = UITextView()
    let placeholder = UILabel()
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
    private var keyboardTransitionOwned = false
    private var textRevision = 0
    private var measuredRevision = -1
    private var measuredWidth: CGFloat = -1
    private var measuredFont: UIFont?
    private var measuredHeight: CGFloat = 0
    private var lastHostWidth: CGFloat = -1
    private var lastReportedClearance: CGFloat = -1
    var measuredClearance: CGFloat { max(62, lastReportedClearance) }
    private weak var textCarrier: UIView?
    private var liftInteraction: ComposerLiftInteraction!
    private var workspaceInputSuppressed = false
    private var overlayFocus: ComposerOverlayFocus?
    private var overlayFocusReason = "none"
#if DEBUG
    private var overlayFocusEvents: [String] = []
#endif

    private func recordOverlayFocusEvent(_ event: String) {
#if DEBUG
        guard overlayFocus != nil || overlayFocusReason == "restored" else { return }
        overlayFocusEvents.append("\(event)[focused=\(editor.isFirstResponder),state=\(currentState),suppressed=\(workspaceInputSuppressed),guide=\(keyboardLayoutGuide.layoutFrame)]")
        if overlayFocusEvents.count > 16 { overlayFocusEvents.removeFirst(overlayFocusEvents.count - 16) }
#endif
    }

    func captureOverlayFocus(ownerIsCurrent: @escaping () -> Bool) -> ComposerOverlayFocus? {
        guard !workspaceInputSuppressed, editor.isFirstResponder, editor.markedTextRange == nil,
              let window else { return nil }
        return ComposerOverlayFocus(host: self, window: window, ownerIsCurrent: ownerIsCurrent)
    }

    func queueOverlayFocus(_ token: ComposerOverlayFocus) {
        overlayFocus?.cancel()
        overlayFocus = token
#if DEBUG
        overlayFocusEvents.removeAll()
#endif
        recordOverlayFocusEvent("queue")
        setNeedsLayout()
        consumeOverlayFocusIfReady()
    }

    func cancelOverlayFocus(_ token: ComposerOverlayFocus) {
        if overlayFocus === token { overlayFocus = nil }
    }

    func consumeOverlayFocusIfReady() {
        guard let token = overlayFocus else { return }
        overlayFocusReason = "invalidOwner"
        guard token.isValid else { token.cancel(); return }
        overlayFocusReason = "inputSuppressed"
        guard !workspaceInputSuppressed else { return }
        overlayFocusReason = "unmounted"
        guard let window else { return }
        overlayFocusReason = "editorWindow"
        guard editor.window === window else { return }
        overlayFocusReason = "emptyBounds"
        guard bounds.width > 0, bounds.height > 0, editor.bounds.width > 0 else { return }
        overlayFocusReason = "editorHidden"
        guard !editor.isHidden else { return }
        overlayFocusReason = "interactionDisabled"
        guard isUserInteractionEnabled else { return }
        overlayFocusReason = "windowOrSceneChanged"
        guard token.window === window, window.windowScene.map({ $0.activationState == .foregroundActive }) ?? true else {
            token.cancel(); return
        }
        var node: UIView? = self
        while let current = node {
            overlayFocusReason = "hiddenAncestor:\(type(of: current))"
            guard !current.isHidden, current.alpha > 0 else { return }
            node = current.superview
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController, controller.presentedViewController != nil {
                overlayFocusReason = "presentedController"
                token.cancel(); return
            }
            responder = current.next
        }
        // UIKit's didBeginEditing callback restores the logical Editing state.
        // Run after the bridge's ordinary focus application, or a fresh layout.
        overlayFocusReason = "responderDeclined"
        recordOverlayFocusEvent("restoreAttempt")
        if editor.becomeFirstResponder() {
            overlayFocusReason = "restored"
            recordOverlayFocusEvent("restoreSucceeded")
            overlayFocus = nil
        }
    }

    func setWorkspaceInputSuppressed(_ suppressed: Bool) {
        workspaceInputSuppressed = suppressed
        isUserInteractionEnabled = !suppressed
        accessibilityElementsHidden = suppressed
        // An attached hosting tree can bypass ancestor AX flags. Suppress the
        // actual native editor too, while retaining its identity and layout.
        editor.isHidden = suppressed
        editor.isAccessibilityElement = !suppressed
        editor.accessibilityElementsHidden = suppressed
        plus.accessibilityElementsHidden = suppressed
        primary.accessibilityElementsHidden = suppressed
        plus.isAccessibilityElement = !suppressed
        primary.isAccessibilityElement = !suppressed
        errorLabel.accessibilityElementsHidden = suppressed
        if suppressed, editor.markedTextRange == nil {
            if editor.isFirstResponder { recordOverlayFocusEvent("suppressionResign") }
            editor.resignFirstResponder()
        }
    }

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
        editor.tintColor = .label
        editor.textColor = .label
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.adjustsFontForContentSizeCategory = true
        editor.keyboardDismissMode = .interactive
        editor.isScrollEnabled = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.accessibilityIdentifier = "conversation-composer-input"
        editor.accessibilityLabel = "说点什么吧"
        viewport.addSubview(editor)
        placeholder.text = "说点什么吧"
        placeholder.textColor = .secondaryLabel
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        viewport.addSubview(placeholder)

        for (button, symbol) in [(plus, "plus"), (primary, "arrow.up")] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
                forImageIn: .normal
            )
            button.tintColor = .systemBackground
            button.backgroundColor = .label
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
        liftInteraction = ComposerLiftInteraction(surface: surface, editor: editor) { [weak self] in
            self?.nativeLiftInput ?? SurfaceLiftEligibility(composerSettled: false)
        }
        tap.require(toFail: liftInteraction.recognizer)
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
        consumeOverlayFocusIfReady()
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
        liftInteraction.checkReadiness()
        consumeOverlayFocusIfReady()
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
            return liftInteraction.isInstalled && currentState != .editing ? surface : editor
        }
        return surface
    }

#if DEBUG
    var liftReadinessDiagnostic: String {
        "\(liftInteraction.readinessDiagnostic);composerBounds=\(bounds);keyboardGuide=\(keyboardLayoutGuide.layoutFrame);composerSurface=\(surface.frame);textViewport=\(viewport.frame);presentationState=\(currentState);overlayFocusPending=\(overlayFocus != nil);overlayFocusValid=\(overlayFocus?.isValid ?? false);overlayFocusReason=\(overlayFocusReason);workspaceInputSuppressed=\(workspaceInputSuppressed);editorHidden=\(editor.isHidden);composerMounted=\(window != nil);editorSameWindow=\(editor.window === window);editorCanFocus=\(editor.canBecomeFirstResponder);overlayFocusEvents=\(overlayFocusEvents.joined(separator: " | "))"
    }
#endif

    var keyboardGap: CGFloat {
        keyboardLayoutGuide.layoutFrame.minY - surface.frame.maxY
    }

    var nativeLiftInput: SurfaceLiftEligibility {
        nativeInput(settledPhase: motion.phase == .resting)
    }

    var nativeSidebarInput: SurfaceLiftEligibility {
        nativeInput(settledPhase: motion.phase == .resting || motion.phase == .editing)
    }

    private func nativeInput(settledPhase: Bool) -> SurfaceLiftEligibility {
        let displayed = surface.layer.presentation()?.frame ?? surface.frame
        let settled = settledPhase && window != nil && surface.bounds.width > 0
            && surface.bounds.height > 0 && abs(displayed.minY - surface.frame.minY) <= 0.5
            && abs(displayed.width - surface.frame.width) <= 0.5
            && abs(keyboardGap + bottomConstraint.constant) <= 0.5
        return SurfaceLiftEligibility(isEditing: currentState == .editing || editor.isFirstResponder,
            hasMarkedText: editor.markedTextRange != nil,
            keyboardVisible: liftInteraction.keyboardVisible
                || bounds.maxY - keyboardLayoutGuide.layoutFrame.minY > safeAreaInsets.bottom + 1,
            keyboardTransitioning: liftInteraction.keyboardTransitioning,
            composerSettled: settled, selectionActive: false, quoteDragActive: quotePhase != .idle)
    }

    var surfaceFrame: CGRect { surface.frame }
    var motionGeneration: Int { motion.generation }
    var reportedClearance: CGFloat { lastReportedClearance }
    var previewViewportWidth: CGFloat { viewport.bounds.width }

    private var shelfViewIsHidden: Bool { shelfController?.view.isHidden ?? true }

    func configure(_ next: Configuration) {
        let oldText = configuration?.text
        let oldFont = configuration?.font
        let oldReferences = configuration?.references
        configuration = next
        liftInteraction.configure(next.liftInteraction)
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
        } else {
            let geometryChanged = oldText != next.text || oldFont != next.font
                || oldReferences != next.references
            if motion.phase == .expanding || motion.phase == .collapsing {
                if geometryChanged {
                    // A new target must start at the visible presentation position.
                    render(animated: true, generation: motion.begin(next.state))
                }
            } else if !motion.keepsEditingLayout || geometryChanged {
                render(animated: false)
            }
        }
        liftInteraction.checkReadiness()
    }

    func requestFocus(_ focused: Bool) {
        guard !workspaceInputSuppressed else { return }
        if focused {
            if !editor.isFirstResponder { editor.becomeFirstResponder() }
        } else if editor.markedTextRange == nil, editor.isFirstResponder {
            recordOverlayFocusEvent("bridgeRestingResign")
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
        reportClearance(clearance)
        let apply = {
            self.widthConstraint.constant = layout.size.width
            self.heightConstraint.constant = layout.size.height
            self.bottomConstraint.constant = -layout.bottomSpacing
            self.viewport.frame = targetViewport
            self.placeholder.alpha = state == .editing ? 0.62 : 1
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
        positionPlaceholder()
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
                    self.liftInteraction.checkReadiness()
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
            editor.frame.size.width = max(1, viewport.bounds.width)
            editor.frame.size.height = max(1, viewport.bounds.height)
            positionPlaceholder()
        }
        if let carrier {
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12,
                           animations: { carrier.alpha = 0 },
                           completion: { [weak carrier] _ in carrier?.removeFromSuperview() })
        }
    }

    private func positionPlaceholder() {
        guard let configuration, configuration.text.isEmpty else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: editor.beginningOfDocument)
        let lineHeight = configuration.font.lineHeight
        let caretMidY = caret.midY.isFinite && caret.height > 0 ? caret.midY : lineHeight / 2
        let caretMaxX = caret.maxX.isFinite ? caret.maxX : 0
        let x = caretMaxX + 1
        let height = lineHeight + 2
        placeholder.frame = CGRect(
            x: x, y: caretMidY - height / 2,
            width: max(0, editor.bounds.width - x), height: height
        )
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

    private func reportClearance(_ clearance: CGFloat) {
        guard abs(clearance - lastReportedClearance) > 0.5 else { return }
        lastReportedClearance = clearance
        Task { @MainActor [weak self] in
            guard let self, abs(self.lastReportedClearance - clearance) <= 0.5 else { return }
            self.configuration?.onHeightChanged(clearance)
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
                    self.reportClearance(self.surface.frame.height + 12 + height)
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
        guard window != nil else { return }
        if keyboardTransitionOwned || editor.isFirstResponder {
            configuration?.onKeyboardWillChange()
        }
        guard let info = notification.userInfo,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber,
              let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber else { return }
        keyboardTiming = (duration.doubleValue,
                          UIView.AnimationOptions(rawValue: UInt(curve.intValue) << 16))
        if motion.phase == .editing { render(animated: false) }
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        guard window != nil else { return }
        recordOverlayFocusEvent("keyboardDidHide")
        // This Window-wide notification can finish another editor's hide after
        // our responder handoff, or accompany a hardware keyboard. Native
        // focus wins; didEndEditing still reports a real loss of this editor.
        if !editor.isFirstResponder {
            if currentState == .editing { configuration?.onFocus(false) }
            keyboardTransitionOwned = false
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        recordOverlayFocusEvent("didBeginEditing")
        liftInteraction.checkReadiness()
        keyboardTransitionOwned = true
        configuration?.onFocus(true)
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        recordOverlayFocusEvent("didEndEditing")
        configuration?.onFocus(false)
    }
    func textViewDidChange(_ textView: UITextView) { reportEditor() }
    func textViewDidChangeSelection(_ textView: UITextView) { reportEditor() }

    private func reportEditor() {
        liftInteraction.checkReadiness()
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
        liftInteraction.checkReadiness()
        configuration?.onQuotePhase(phase)
    }
}
