import SwiftUI
import UIKit

@MainActor
struct ConversationSurfaceHost<Content: View>: UIViewControllerRepresentable {
    var request: SurfaceGeometry.Request = .full
    var liftController: SurfaceLiftController?
    var browseController: AppSpaceBrowseController?
    var deleteAction: AppSpaceCardDeletionInteraction.Commit?
    var isDeletionPending: (@MainActor (String) -> Bool)?
    var isWorkspaceVisible: Bool
    var isInputSuppressed: Bool
    var isReturnProxyHidden: Bool
    var restingCornerRadius: CGFloat
    var squareBottomCorners: Bool
    var sidebarOffset: CGFloat
    var sidebarSettlement: UUID?
    var onSidebarSettled: ((UUID) -> Void)?
    var onNativeLayout: ((WorkspaceNativeLayoutReceipt?) -> Void)?
    var contentOwner: ObjectIdentifier?
    let content: Content

    init(request: SurfaceGeometry.Request = .full, liftController: SurfaceLiftController? = nil,
         browseController: AppSpaceBrowseController? = nil,
         deleteAction: AppSpaceCardDeletionInteraction.Commit? = nil,
         isDeletionPending: (@MainActor (String) -> Bool)? = nil,
         isWorkspaceVisible: Bool = true,
         isInputSuppressed: Bool = false, isReturnProxyHidden: Bool = false,
         restingCornerRadius: CGFloat = 0, squareBottomCorners: Bool = false,
         sidebarOffset: CGFloat = 0, sidebarSettlement: UUID? = nil,
         onSidebarSettled: ((UUID) -> Void)? = nil,
         onNativeLayout: ((WorkspaceNativeLayoutReceipt?) -> Void)? = nil,
         contentOwner: ObjectIdentifier? = nil,
         @ViewBuilder content: () -> Content) {
        self.request = request
        self.liftController = liftController
        self.browseController = browseController
        self.deleteAction = deleteAction
        self.isDeletionPending = isDeletionPending
        self.isWorkspaceVisible = isWorkspaceVisible
        self.isInputSuppressed = isInputSuppressed
        self.isReturnProxyHidden = isReturnProxyHidden
        self.restingCornerRadius = restingCornerRadius
        self.squareBottomCorners = squareBottomCorners
        self.sidebarOffset = sidebarOffset
        self.sidebarSettlement = sidebarSettlement
        self.onSidebarSettled = onSidebarSettled
        self.onNativeLayout = onNativeLayout
        self.contentOwner = contentOwner
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ConversationSurfaceViewController<Content> {
        let controller = ConversationSurfaceViewController(content: content, request: request)
        controller.topEdge.setContentOwner(contentOwner)
        liftController?.bind(controller)
        controller.bindBrowse(browseController)
        controller.bindDeletion(deleteAction, isPending: isDeletionPending)
        controller.onNativeLayout = onNativeLayout
        controller.setRestingCornerRadius(restingCornerRadius)
        controller.setInputSuppressed(isInputSuppressed)
        controller.setReturnProxyHidden(isReturnProxyHidden)
        controller.setWorkspaceVisible(isWorkspaceVisible)
        controller.setSquareBottomCorners(squareBottomCorners)
        controller.setSidebar(offset: sidebarOffset, settlement: sidebarSettlement, completion: onSidebarSettled)
        return controller
    }

    func updateUIViewController(_ controller: ConversationSurfaceViewController<Content>, context: Context) {
        controller.topEdge.setContentOwner(contentOwner)
        // Content is installed once. Its own observed state drives updates; progress
        // must not replace the hosting root or invalidate the Timeline each frame.
        if let liftController {
            liftController.bind(controller)
        } else {
            controller.liftController?.unbind(controller)
            _ = controller.apply(request)
        }
        controller.bindBrowse(browseController)
        controller.bindDeletion(deleteAction, isPending: isDeletionPending)
        controller.onNativeLayout = onNativeLayout
        controller.setRestingCornerRadius(restingCornerRadius)
        controller.setInputSuppressed(isInputSuppressed)
        controller.setReturnProxyHidden(isReturnProxyHidden)
        controller.setWorkspaceVisible(isWorkspaceVisible)
        controller.setSquareBottomCorners(squareBottomCorners)
        controller.setSidebar(offset: sidebarOffset, settlement: sidebarSettlement, completion: onSidebarSettled)
        controller.scheduleNativeLayoutReceipt()
    }

    static func dismantleUIViewController(_ controller: ConversationSurfaceViewController<Content>,
                                         coordinator: Void) {
        controller.onNativeLayout?(nil)
        controller.onNativeLayout = nil
        controller.cancelSidebar()
        controller.unbindDeletion()
        controller.unbindBrowse()
        controller.liftController?.unbind(controller)
    }
}

@MainActor
final class ConversationSurfaceViewController<Content: View>: UIViewController {
    let contentController: SurfaceHostingController<Content>
    let topEdge = ConversationTopEdgeMaterial(frame: .zero)
    private var restingCornerRadius: CGFloat = 0
    let surfaceView = SurfaceClipView()
    private let sidebarShadowView = UIView()
    private(set) var presentation = SurfaceGeometry.Presentation.full
    private var request = SurfaceGeometry.Request.full
    weak var liftController: SurfaceLiftController?
    private(set) var browseInteraction: AppSpaceBrowseInteraction?
    private(set) var deletionInteraction: AppSpaceCardDeletionInteraction?
    var onViewportChanged: (() -> Void)?
    var onNativeLayout: ((WorkspaceNativeLayoutReceipt?) -> Void)?
    private var layoutReceiptGeneration: UInt64 = 0
    private var inputSuppressed = false
    private var returnProxyHidden = false
    private var lastViewport: CGRect?
    private var lastInsets: UIEdgeInsets?
    private let cropMask = UIView()
    private var animator: UIViewPropertyAnimator?
    private var sidebarOffset: CGFloat = 0
    private var sidebarSettlement: UUID?
    private var sidebarAnimator: UIViewPropertyAnimator?
    private var squareBottomCorners = false
    private let windowCornerGeometry = WindowCornerGeometry()
    private let sidebarShadowOpacity: Float = 0.2
    private let sidebarShadowRadius: CGFloat = 18
    private let sidebarShadowHorizontalOffset: CGFloat = 8
    private var sidebarShadowDirection: CGFloat = -1
#if DEBUG
    // Tests pause the real animator so a busy simulator cannot skip settlement.
    var liftAnimatorForTesting: UIViewPropertyAnimator? {
        if recordsLiftLifecycleForTesting {
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = lastAnimatorSampleForTesting {
                maxAnimatorSampleGapForTesting = max(maxAnimatorSampleGapForTesting, now - previous)
            }
            lastAnimatorSampleForTesting = now
            animatorSampleCountForTesting += 1
            if lastAnimatorPresenceForTesting != (animator != nil) {
                recordLiftLifecycle("sample present=\(animator != nil)")
                lastAnimatorPresenceForTesting = animator != nil
            }
        }
        return animator
    }
    var recordsLiftLifecycleForTesting = false
    private(set) var liftLifecycleForTesting: [String] = []
    private var lastAnimatorSampleForTesting: TimeInterval?
    private var lastAnimatorPresenceForTesting: Bool?
    private(set) var animatorSampleCountForTesting = 0
    private(set) var maxAnimatorSampleGapForTesting = 0.0

    var visibilityDiagnostic: String {
        "visible=\(workspaceVisible),hidden=\(view.isHidden),axHidden=\(contentController.view.accessibilityElementsHidden),suppressed=\(inputSuppressed),proxyHidden=\(returnProxyHidden)"
    }

    var interactionDiagnostic: String {
        func editors(in node: UIView) -> [UITextView] {
            if let editor = node as? UITextView,
               editor.accessibilityIdentifier == "conversation-composer-input" { return [editor] }
            return node.subviews.flatMap { editors(in: $0) }
        }
        func chain(_ view: UIView?) -> String {
            var node = view
            var values: [String] = []
            while let current = node, values.count < 14 {
                values.append("\(type(of: current))[hidden=\(current.isHidden),interaction=\(current.isUserInteractionEnabled),alpha=\(current.alpha)]")
                node = current.superview
            }
            return values.joined(separator: ">")
        }
        let mounted = editors(in: contentController.view) + (liftController?.externalComposer.map { [$0.editor] } ?? [])
        var fields = ["host=\(ObjectIdentifier(self))", "phase=\(String(describing: liftController?.state.phase))",
            "edgeVisible=\(surfaceView.currentEdgeVisible)",
            "visible=\(workspaceVisible)", "root=\(chain(view))",
            "contentInteraction=\(contentController.view.isUserInteractionEnabled)",
            "contentAXHidden=\(contentController.view.accessibilityElementsHidden)",
            "surfaceAX=\(surfaceView.isAccessibilityElement)", "activate=\(surfaceView.onActivate != nil)",
            "editors=\(mounted.count)", "browse=\(browseInteraction?.diagnostic ?? "none")"]
        fields.append("sidebar=\(liftController?.workspaceNavigation?.nativeDiagnostic ?? "unbound")")
        fields.append("sidebarCanOpen=\(liftController?.sidebarNativeContext?()?.allowsOpening ?? false)")
        fields.append("timeline=\(liftController?.workspacePaneDiagnostic?() ?? "unbound")")
        if let window = view.window {
            fields.append("windowSafeTop=\(window.safeAreaInsets.top)")
            fields.append("windowCornerRadius=\(windowConcentricCornerRadius())")
            fields.append("hostFrame=\(view.convert(view.bounds, to: window))")
            fields.append("contentFrame=\(contentController.view.convert(contentController.view.bounds, to: window))")
            fields.append("contentSafeArea=\(contentController.view.safeAreaInsets)")
            fields.append("surfaceFrame=\(surfaceView.convert(surfaceView.bounds, to: window))")
            fields.append("topEdgeFrame=\(topEdge.convert(topEdge.bounds, to: window))")
            fields.append("topEdgeCaptures=\(topEdge.captureCount)")
            fields.append(topEdge.samplingDiagnostic)
            fields.append("topEdgeAttempts=\(topEdge.captureAttempts);topEdgeFailures=\(topEdge.captureFailures);topEdgeCaptureMs=\(topEdge.lastCaptureMilliseconds);topEdgeRenderMs=\(topEdge.lastRenderMilliseconds)")
            func scrollViews(in node: UIView) -> [UIScrollView] {
                let own = (node as? UIScrollView).flatMap { $0 is UITextView ? nil : $0 }.map { [$0] } ?? []
                return own + node.subviews.flatMap { scrollViews(in: $0) }
            }
            for (index, scroll) in scrollViews(in: contentController.view).enumerated() {
                if index == 0 {
                    let insets = scroll.adjustedContentInset
                    // SwiftUI can place horizontal safe-area padding in its
                    // content while UIScrollView reports zero adjusted Insets.
                    // These are overlapping exclusions, not additive padding.
                    let left = max(insets.left, scroll.safeAreaInsets.left)
                    let right = max(insets.right, scroll.safeAreaInsets.right)
                    let readable = CGRect(x: scroll.bounds.minX + left,
                        y: scroll.bounds.minY + insets.top,
                        width: max(0, scroll.bounds.width - left - right),
                        height: max(0, scroll.bounds.height - insets.top - insets.bottom))
                    fields.append("timelineVisibleFrame=\(scroll.convert(readable, to: window))")
                }
                let point = scroll.convert(CGPoint(x: scroll.bounds.minX + scroll.bounds.width * 0.98,
                    y: scroll.bounds.minY + scroll.bounds.height * 0.25), to: window)
                fields.append("nativeScroll=\(type(of: scroll));frame=\(scroll.convert(scroll.bounds, to: window));size=\(scroll.contentSize);offset=\(scroll.contentOffset);insets=\(scroll.contentInset);adjustedInsets=\(scroll.adjustedContentInset);safeInsets=\(scroll.safeAreaInsets);marginPoint=\(point);marginHit=\(chain(window.hitTest(point, with: nil)))")
            }
        }
        if let editor = mounted.first, let window = view.window {
            let point = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: window)
            fields.append("editorIdentity=\(ObjectIdentifier(editor))")
            fields.append("focused=\(editor.isFirstResponder)")
            fields.append("editorFrame=\(editor.convert(editor.bounds, to: window))")
            fields.append("editorTextLength=\((editor.text ?? "").utf16.count)")
            fields.append("editorSelection=(\(editor.selectedRange.location),\(editor.selectedRange.length))")
            fields.append("editorLineHeight=\(editor.font?.lineHeight ?? 0)")
            var ancestor: UIView? = editor
            while let current = ancestor {
                if let composer = current as? ComposerHostView {
                    fields.append(composer.liftReadinessDiagnostic)
                    break
                }
                ancestor = current.superview
            }
            fields.append("point=\(point)")
            fields.append("hit=\(chain(window.hitTest(point, with: nil)))")
        }
        return fields.joined(separator: ";")
    }
#endif
    private var animationIdentity: UUID?
    private var retainsAnimationMask = false
    private var workspaceVisible = true
    private var contentConstraints: [NSLayoutConstraint] = []

    init(content: Content, request: SurfaceGeometry.Request = .full) {
        contentController = SurfaceHostingController(rootView: content)
        if request.isValid { self.request = request }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }

    override func loadView() {
        let container = SurfaceHitView()
        container.surfaceView = surfaceView
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        surfaceView.layer.cornerCurve = .continuous
        surfaceView.clipsToBounds = true
        sidebarShadowView.backgroundColor = .systemBackground
        sidebarShadowView.isUserInteractionEnabled = false
        sidebarShadowView.isAccessibilityElement = false
        sidebarShadowView.accessibilityElementsHidden = true
        sidebarShadowView.layer.cornerCurve = .continuous
        sidebarShadowView.layer.masksToBounds = false
        sidebarShadowView.layer.shadowColor = UIColor.black.cgColor
        sidebarShadowView.layer.shadowOpacity = sidebarShadowOpacity
        sidebarShadowView.layer.shadowRadius = sidebarShadowRadius
        sidebarShadowView.alpha = 0
        sidebarShadowView.isHidden = true
        cropMask.backgroundColor = .black
        cropMask.layer.cornerCurve = .continuous
        view.addSubview(sidebarShadowView)
        view.addSubview(surfaceView)
        addChild(contentController)
        let contentView = contentController.view!
        contentView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(contentView)
        contentConstraints = [
            contentView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(contentConstraints)
        contentController.didMove(toParent: self)
        surfaceView.addSubview(topEdge)
        topEdge.configure(source: contentView, safeTop: view.safeAreaInsets.top)
#if DEBUG
        if ProcessInfo.processInfo.environment["ZEN_TOP_CAPTURE_DISABLED_DIAGNOSTIC"] == "1" {
            topEdge.setWorkspaceVisible(false)
        }
#endif
        contentController.onContentLayout = { [weak topEdge] in topEdge?.invalidateContent() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Bounds and center remain independent of the presentation transform.
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let center = CGPoint(x: view.bounds.midX + sidebarOffset, y: view.bounds.midY)
        if surfaceView.bounds != bounds { surfaceView.bounds = bounds }
        if surfaceView.center != center { surfaceView.center = center }
        // Use the untransformed host's actual safe area. A lower Split pane and
        // landscape have no status area; Lift and Sidebar move this decoration
        // with the Surface, independently of the retained timeline's layout.
        topEdge.frame = CGRect(x: 0, y: 0, width: bounds.width,
            height: view.safeAreaInsets.top > 0
                ? min(bounds.height, view.safeAreaInsets.top + ConversationTopEdgeMaterial.fadeHeight) : 0)
        topEdge.configure(source: contentController.view, safeTop: view.safeAreaInsets.top)
        if workspaceVisible { contentController.preserveContainerSafeArea(view.safeAreaInsets) }
        // onAppear may restore Card before a usable viewport exists. Notify the
        // first layout too, so that Card's first Return has a resolved Lift target.
        let changed = lastViewport != view.bounds || lastInsets != view.safeAreaInsets
        lastViewport = view.bounds
        lastInsets = view.safeAreaInsets
        if changed { onViewportChanged?() }
        browseInteraction?.updateViewport()
        _ = apply(request)
        scheduleNativeLayoutReceipt()
    }

    func scheduleNativeLayoutReceipt() {
        guard onNativeLayout != nil else { return }
        layoutReceiptGeneration &+= 1
        let generation = layoutReceiptGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.layoutReceiptGeneration == generation, let window = self.view.window else { return }
            self.onNativeLayout?(WorkspaceNativeLayoutReceipt(hostID: ObjectIdentifier(self),
                windowID: ObjectIdentifier(window), frame: self.view.convert(self.view.bounds, to: window)))
        }
    }

    func setRestingCornerRadius(_ radius: CGFloat) {
        restingCornerRadius = radius
        updateSurfaceDecoration()
    }

    func setSquareBottomCorners(_ square: Bool) {
        guard squareBottomCorners != square else { return }
        squareBottomCorners = square
        updateSurfaceDecoration()
    }

    func setInputSuppressed(_ suppressed: Bool) {
        inputSuppressed = suppressed
        liftController?.refreshCardAccessibility()
    }

    var allowsSidebarInput: Bool {
        guard allowsSidebarClosing else { return false }
        func hasNavigation(_ controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 { return true }
            return controller.children.contains { hasNavigation($0) }
        }
        guard !hasNavigation(contentController), let composer = findComposer(in: contentController.view) ?? liftController?.externalComposer else { return false }
        var input = composer.nativeSidebarInput
        input.selectionActive = composer.editor.selectedTextRange.map { !$0.isEmpty } ?? false
        return WorkspaceSidebarEligibility.allowsNativeInput(input)
    }

    private func findComposer(in node: UIView) -> ComposerHostView? {
        if let composer = node as? ComposerHostView { return composer }
        for child in node.subviews { if let composer = findComposer(in: child) { return composer } }
        return nil
    }

    func captureOverlayFocus(ownerIsCurrent: @escaping () -> Bool) -> ComposerOverlayFocus? {
        guard allowsSidebarInput else { return nil }
        return (findComposer(in: contentController.view) ?? liftController?.externalComposer)?.captureOverlayFocus(ownerIsCurrent: ownerIsCurrent)
    }

    var allowsSidebarClosing: Bool {
        workspaceVisible && !inputSuppressed && !returnProxyHidden && !hasPresentedOverlay
    }

    func setSidebar(offset: CGFloat, settlement: UUID?, completion: ((UUID) -> Void)?) {
        guard offset.isFinite else { return }
        guard sidebarOffset != offset || sidebarSettlement != settlement else {
            updateSurfaceDecoration()
            return
        }
        let displayedCenter = sidebarAnimator == nil ? nil : surfaceView.layer.presentation()?.position
        let displayedShadowCenter = sidebarAnimator == nil ? nil : sidebarShadowView.layer.presentation()?.position
        let displayedShadowAlpha = sidebarAnimator == nil ? nil : sidebarShadowView.layer.presentation()?.opacity
        sidebarAnimator?.stopAnimation(true)
        sidebarAnimator = nil
        if let displayedCenter { surfaceView.center = displayedCenter }
        if let displayedShadowCenter { sidebarShadowView.center = displayedShadowCenter }
        if let displayedShadowAlpha { sidebarShadowView.alpha = CGFloat(displayedShadowAlpha) }
        sidebarOffset = offset
        sidebarSettlement = settlement
        // Keep the exposed side while a closing settlement targets zero offset.
        if offset != 0 { sidebarShadowDirection = offset > 0 ? -1 : 1 }
        // Lift alone owns transform. Navigation changes center while the native
        // bounds and hosting child's original safe area remain unchanged.
        let center = CGPoint(x: view.bounds.midX + offset, y: view.bounds.midY)
        let shadowAlpha = sidebarShadowAlpha(for: offset)
        guard let settlement else {
            surfaceView.center = center
            sidebarShadowView.center = center
            sidebarShadowView.alpha = shadowAlpha
            updateSurfaceDecoration()
            return
        }
        sidebarShadowView.isHidden = !workspaceVisible || returnProxyHidden
        if UIAccessibility.isReduceMotionEnabled {
            surfaceView.center = center
            sidebarShadowView.center = center
            sidebarShadowView.alpha = shadowAlpha
            updateSurfaceDecoration()
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.sidebarSettlement == settlement else { return }
                completion?(settlement)
            }
            return
        }
        let animation = UIViewPropertyAnimator(duration: 0.22, curve: .easeOut) { [weak self] in
            self?.surfaceView.center = center
            self?.sidebarShadowView.center = center
            self?.sidebarShadowView.alpha = shadowAlpha
        }
        sidebarAnimator = animation
        updateSurfaceDecoration()
        animation.addCompletion { [weak self] position in
            guard let self, self.sidebarSettlement == settlement, position == .end else { return }
            self.sidebarAnimator = nil
            self.updateSurfaceDecoration()
            completion?(settlement)
        }
        animation.startAnimation()
    }

    func cancelSidebar() {
        sidebarAnimator?.stopAnimation(true)
        sidebarAnimator = nil
        sidebarSettlement = nil
        sidebarOffset = 0
        surfaceView.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        sidebarShadowView.center = surfaceView.center
        sidebarShadowView.alpha = 0
        updateSurfaceDecoration()
    }

    func setReturnProxyHidden(_ hidden: Bool) {
        returnProxyHidden = hidden
        surfaceView.isHidden = hidden
        updateSurfaceDecoration()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if workspaceVisible { contentController.preserveContainerSafeArea(view.safeAreaInsets) }
        view.setNeedsLayout()
    }

    @discardableResult
    func apply(_ candidate: SurfaceGeometry.Request, force: Bool = false) -> Bool {
        guard let resolved = SurfaceGeometry.resolve(size: view.bounds.size, safeArea: view.safeAreaInsets, request: candidate) else { return false }
        request = candidate
        guard force || presentation != resolved else { updateCrop(); return true }
        presentation = resolved
        surfaceView.transform = CGAffineTransform(a: resolved.scale, b: 0, c: 0, d: resolved.scale, tx: resolved.translation.width, ty: resolved.translation.height)
        updateCrop()
        return true
    }

    private func updateCrop() {
        let fraction = presentation.clipFraction
        let cropped = fraction != CGSize(width: 1, height: 1)
        guard cropped || retainsAnimationMask else {
            surfaceView.mask = nil
            surfaceView.visibleRect = nil
            updateSurfaceDecoration()
            return
        }
        let width = surfaceView.bounds.width * fraction.width
        let height = surfaceView.bounds.height * fraction.height
        cropMask.frame = CGRect(x: (surfaceView.bounds.width - width) / 2,
                                y: (surfaceView.bounds.height - height) / 2,
                                width: width, height: height)
        cropMask.layer.cornerRadius = presentation.cornerRadius
        surfaceView.mask = cropMask
        surfaceView.visibleRect = cropMask.frame
        updateSurfaceDecoration()
    }

    private var isStableFullSurface: Bool {
        presentation == .full && surfaceView.transform == .identity && animator == nil
            && !retainsAnimationMask && surfaceView.mask == nil
    }

    private func sidebarShadowAlpha(for offset: CGFloat) -> CGFloat {
        let threshold = max(1, view.bounds.width * 0.15)
        return min(1, abs(offset) / threshold)
    }

    private func updateSurfaceDecoration() {
        let windowRadius = restingCornerRadius == 0 && isStableFullSurface
            ? windowConcentricCornerRadius() : 0
        let radius = max(restingCornerRadius, max(presentation.cornerRadius, windowRadius))
        let squareBottom = squareBottomCorners && isStableFullSurface
        let topCorners: CACornerMask = .layerMinXMinYCorner.union(.layerMaxXMinYCorner)
        let allCorners = topCorners.union(.layerMinXMaxYCorner).union(.layerMaxXMaxYCorner)
        let roundedCorners = squareBottom ? topCorners : allCorners

        surfaceView.layer.cornerRadius = radius
        surfaceView.layer.maskedCorners = roundedCorners
        sidebarShadowView.bounds = surfaceView.bounds
        sidebarShadowView.center = surfaceView.center
        sidebarShadowView.transform = surfaceView.transform
        sidebarShadowView.layer.cornerRadius = radius
        sidebarShadowView.layer.maskedCorners = roundedCorners
        sidebarShadowView.layer.shadowOffset = CGSize(width: sidebarShadowDirection * sidebarShadowHorizontalOffset, height: 0)
        // Cast the same continuous corner silhouette as the foreground. A
        // circular UIBezierPath leaves grey wedges between the two curves.
        sidebarShadowView.layer.shadowPath = nil
        sidebarShadowView.overrideUserInterfaceStyle = contentController.traitCollection.userInterfaceStyle
        sidebarShadowView.isHidden = !workspaceVisible || returnProxyHidden
            || (sidebarOffset == 0 && sidebarSettlement == nil)
        if sidebarAnimator == nil {
            sidebarShadowView.alpha = sidebarShadowAlpha(for: sidebarOffset)
        }
    }

    private func windowConcentricCornerRadius() -> CGFloat {
        guard let window = view.window else { return 0 }
        return windowCornerGeometry.radius(in: window)
    }

    func setLiftInteraction(_ phase: SurfaceLiftState.Phase, returnAction: @escaping () -> Bool) {
        surfaceView.setCurrentEdgeVisible(phase == .card)
        let frozen = phase == .settling || phase == .card || phase == .split
        contentController.view.isUserInteractionEnabled = workspaceVisible && !frozen && !inputSuppressed && !returnProxyHidden
        contentController.view.accessibilityElementsHidden = !workspaceVisible || frozen || inputSuppressed || returnProxyHidden
        surfaceView.isAccessibilityElement = workspaceVisible && frozen && !inputSuppressed && !returnProxyHidden
        surfaceView.accessibilityIdentifier = phase == .card || liftController?.heldReturnCardLabel != nil ? "workspace-current-card" : nil
        surfaceView.accessibilityLabel = "当前会话"
        let isNew = browseInteraction?.controller.isNewEntry == true
        surfaceView.accessibilityHint = isNew ? "轻点创建新对话" : "轻点返回会话"
        surfaceView.accessibilityTraits = .button
        surfaceView.onActivate = frozen ? { [weak self] in
            self?.browseInteraction?.cancel()
            return returnAction()
        } : nil
        surfaceView.accessibilityCustomActions = frozen
            ? [UIAccessibilityCustomAction(name: isNew ? "创建新对话" : "返回会话", target: surfaceView,
                                           selector: #selector(SurfaceClipView.activateReturn))] : nil
        if phase == .card, let browse = browseInteraction, browse.hasNavigationActions {
            var actions = surfaceView.accessibilityCustomActions ?? []
            if browse.controller.state.older != nil {
                actions.append(UIAccessibilityCustomAction(name: "上一会话") { [weak browse] _ in
                    browse?.navigate(.older) ?? false
                })
            }
            if browse.controller.state.newer != nil {
                actions.append(UIAccessibilityCustomAction(name: "下一会话") { [weak browse] _ in
                    browse?.navigate(.newer) ?? false
                })
            }
            if !isNew, browse.controller.canEditCurrentMetadata {
                if let deletion = deletionInteraction, deletion.canTrigger {
                    actions.append(UIAccessibilityCustomAction(name: "删除会话") { [weak deletion] _ in
                        deletion?.triggerAccessibilityDelete() ?? false
                    })
                }
                actions.append(UIAccessibilityCustomAction(name: "会话菜单") { [weak browse] _ in
                    guard let browse, browse.canNavigate else { return false }
                    return browse.controller.onOpenActions?() ?? false
                })
            }
            surfaceView.accessibilityCustomActions = actions
        }
        browseInteraction?.updateAvailability()
        deletionInteraction?.updateAvailability()
    }

    func bindBrowse(_ controller: AppSpaceBrowseController?) {
        if let browseInteraction, browseInteraction.controller === controller,
           browseInteraction.isCurrentOwner { return }
        unbindBrowse()
        guard let controller else { return }
        loadViewIfNeeded()
        browseInteraction = AppSpaceBrowseInteraction(surface: surfaceView, coordinates: view, controller: controller,
            canBrowse: { [weak self, weak controller] in
                guard let self, let lift = self.liftController else { return false }
                return self.browseInteraction?.isCurrentOwner == true
                    && controller?.isPresented == true && lift.state.phase == .card
                    && !lift.isPreparingReturn && !lift.overlayPresented && !self.hasPresentedOverlay
            }, render: { [weak self, weak controller] card in
                guard let self, let controller, self.liftController?.state.phase == .card,
                      let pose = AppSpaceBrowseGeometry.pose(for: card,
                        size: controller.viewportSize, safeArea: controller.safeArea) else { return false }
                let rendered = self.apply(.init(to: pose, progress: 1), force: true)
                if rendered { self.surfaceView.alpha = CGFloat(card.opacity) }
                return rendered
            }, refreshAccessibility: { [weak self] in self?.liftController?.refreshCardAccessibility() })
        browseInteraction?.updateAvailability()
    }

    func unbindBrowse() {
        unbindDeletion()
        browseInteraction?.unbind()
        browseInteraction = nil
    }

    func bindDeletion(_ commit: AppSpaceCardDeletionInteraction.Commit?,
                      isPending: (@MainActor (String) -> Bool)?) {
        guard let commit, let isPending, let browse = browseInteraction?.controller else {
            unbindDeletion()
            return
        }
        if let deletionInteraction {
            deletionInteraction.updateActions(commit: commit, stillPending: isPending)
            deletionInteraction.updateAvailability()
            return
        }
        deletionInteraction = AppSpaceCardDeletionInteraction(surface: surfaceView,
            coordinates: view, browse: browse,
            canDelete: { [weak self, weak browse] in
                guard let self, let browse, let lift = self.liftController else { return false }
                return browse.isPresented && !browse.interactionSuspended
                    && self.browseInteraction?.isCurrentOwner == true
                    && browse.state.phase == .idle && browse.canEditCurrentMetadata
                    && lift.state.phase == .card && !lift.isPreparingReturn
                    && !lift.overlayPresented && !self.hasPresentedOverlay
            },
            refreshAccessibility: { [weak self] in self?.liftController?.refreshCardAccessibility() },
            stillPending: isPending,
            commit: commit)
        deletionInteraction?.updateAvailability()
        liftController?.refreshCardAccessibility()
    }

    func unbindDeletion() {
        deletionInteraction?.unbind()
        deletionInteraction = nil
    }

    func setWorkspaceVisible(_ visible: Bool) {
        loadViewIfNeeded()
#if DEBUG
        topEdge.setWorkspaceVisible(visible && ProcessInfo.processInfo.environment["ZEN_TOP_CAPTURE_DISABLED_DIAGNOSTIC"] != "1")
#else
        topEdge.setWorkspaceVisible(visible)
#endif
        let contentView = contentController.view!
        if !visible {
            // A nested hosting accessibility tree can remain discoverable despite
            // hidden flags. Retain its owners and native views, but remove the
            // inactive tree from the window until this Pane is presented again.
            liftController?.setWorkspaceVisible(false)
            contentController.suspendsContainerInsets = true
            workspaceVisible = false
            if contentView.superview != nil {
                NSLayoutConstraint.deactivate(contentConstraints)
                contentView.removeFromSuperview()
            }
        } else if contentView.superview == nil {
            surfaceView.insertSubview(contentView, belowSubview: topEdge)
            NSLayoutConstraint.activate(contentConstraints)
            workspaceVisible = true
            contentController.suspendsContainerInsets = false
            view.setNeedsLayout()
            view.layoutIfNeeded()
            contentController.preserveContainerSafeArea(view.safeAreaInsets)
            contentView.layoutIfNeeded()
        } else {
            workspaceVisible = true
        }
        view.isHidden = !visible
        view.isUserInteractionEnabled = visible
        view.accessibilityElementsHidden = !visible
        updateSurfaceDecoration()
        // didMoveToWindow/layout run while the retained host is still hidden.
        // Recheck the queued responder after that final visibility gate opens.
        if visible { findComposer(in: contentView)?.consumeOverlayFocusIfReady() }
        // Resume after the retained view has its mounted viewport and safe area.
        liftController?.setWorkspaceVisible(visible)
        liftController?.refreshCardAccessibility()
    }

    var hasPresentedOverlay: Bool {
        var controller: UIViewController? = contentController
        while let current = controller {
            if current.presentedViewController != nil { return true }
            controller = current.parent
        }
        return false
    }

    func cancelLiftAnimation() {
        recordLiftLifecycle("cancel animator=\(animator != nil),identity=\(String(describing: animationIdentity))")
#if DEBUG
        if recordsLiftLifecycleForTesting, animator != nil {
            recordLiftLifecycle("cancel-stack bounds=\(view.bounds),insets=\(view.safeAreaInsets),window=\(view.window != nil),key=\(view.window?.isKeyWindow == true),stack=\(Thread.callStackSymbols.prefix(12).joined(separator: " / "))")
        }
#endif
        animationIdentity = nil
        animator?.stopAnimation(true)
        animator = nil
        retainsAnimationMask = false
    }

    func resetLiftPresentation() {
        cancelLiftAnimation()
        // A transient zero viewport cannot resolve pixels, but the next layout
        // must still use Full instead of resurrecting the interrupted request.
        request = .full
        // The animator's cached endpoint can already be Full while stopping it
        // leaves the native view at an intermediate transform. Apply real pixels.
        UIView.performWithoutAnimation { _ = apply(.full, force: true) }
    }

    func captureLiftProgress(target: SurfaceGeometry.Pose, restingPose: SurfaceGeometry.Pose = .full) -> Double {
        var progress = request.progress
        if animator != nil, let visible = surfaceView.layer.presentation()?.transform {
            let available = CGSize(width: view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                                   height: view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom)
            let candidates: [(magnitude: CGFloat, fraction: CGFloat)] = [
                (abs((target.scale - restingPose.scale) * view.bounds.width),
                 abs(target.scale - restingPose.scale) > 0.000001
                    ? (visible.m11 - restingPose.scale) / (target.scale - restingPose.scale) : 0),
                (abs((target.translation.width - restingPose.translation.width) * available.width),
                 abs(target.translation.width - restingPose.translation.width) > 0.000001
                    ? (visible.m41 / available.width - restingPose.translation.width)
                        / (target.translation.width - restingPose.translation.width) : 0),
                (abs((target.translation.height - restingPose.translation.height) * available.height),
                 abs(target.translation.height - restingPose.translation.height) > 0.000001
                    ? (visible.m42 / available.height - restingPose.translation.height)
                        / (target.translation.height - restingPose.translation.height) : 0)
            ]
            if let strongest = candidates.max(by: { $0.magnitude < $1.magnitude }),
               strongest.magnitude > 0.000001, strongest.fraction.isFinite {
                progress = strongest.fraction
            }
        }
        progress = min(1, max(0, progress))
        cancelLiftAnimation()
        UIView.performWithoutAnimation { _ = apply(.init(from: restingPose, to: target, progress: progress)) }
        return Double(progress)
    }

    func animateLift(target: SurfaceGeometry.Pose, from: Double, to: Double,
                     restingPose: SurfaceGeometry.Pose = .full,
                     animated: Bool, completion: @escaping (Bool) -> Void) {
        recordLiftLifecycle("request from=\(from),to=\(to),animated=\(animated),reduceMotion=\(UIAccessibility.isReduceMotionEnabled),animationsEnabled=\(UIView.areAnimationsEnabled)")
        cancelLiftAnimation()
        _ = apply(.init(from: restingPose, to: target, progress: CGFloat(from)))
        guard animated, !UIAccessibility.isReduceMotionEnabled, abs(to - from) > 0.000001 else {
            let applied = apply(.init(from: restingPose, to: target, progress: CGFloat(to)))
            recordLiftLifecycle("synchronous-finish applied=\(applied)")
            completion(applied)
            return
        }
        retainsAnimationMask = true
        updateCrop()
        let identity = UUID()
        animationIdentity = identity
        let animation = UIViewPropertyAnimator(duration: 0.28, curve: .easeInOut) { [weak self] in
            _ = self?.apply(.init(from: restingPose, to: target, progress: CGFloat(to)))
        }
        animation.isManualHitTestingEnabled = true
        animator = animation
        recordLiftLifecycle("create id=\(identity),duration=0.28")
        animation.addCompletion { [weak self] position in
            self?.recordLiftLifecycle("completion id=\(identity),position=\(position.rawValue),identityMatches=\(self?.animationIdentity == identity)")
            guard let self, self.animationIdentity == identity else { return }
            self.animationIdentity = nil
            self.animator = nil
            self.retainsAnimationMask = false
            self.updateCrop()
            completion(position == .end)
        }
        animation.startAnimation()
        recordLiftLifecycle("started id=\(identity),state=\(animation.state.rawValue),running=\(animation.isRunning)")
    }

    func convergeLift(to pose: SurfaceGeometry.Pose, animated: Bool,
                      completion: @escaping (Bool) -> Void) {
        recordLiftLifecycle("converge animated=\(animated),reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
        // A reversed settlement starts at visible pixels, not the animator's
        // cached endpoint or a scalar projected onto a different Lift path.
        if animator != nil, let visible = surfaceView.layer.presentation() {
            let available = CGSize(width: view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom)
            if available.width > 0, available.height > 0 {
                let transform = visible.transform
                let captured = SurfaceGeometry.Pose(scale: transform.m11,
                    translation: CGSize(width: transform.m41 / available.width, height: transform.m42 / available.height),
                    cornerRadius: visible.cornerRadius, clipFraction: presentation.clipFraction)
                cancelLiftAnimation()
                UIView.performWithoutAnimation { _ = apply(.init(to: captured, progress: 1), force: true) }
            }
        }
        cancelLiftAnimation()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            completion(apply(.init(to: pose, progress: 1)))
            return
        }
        retainsAnimationMask = true
        updateCrop()
        let identity = UUID()
        animationIdentity = identity
        let animation = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) { [weak self] in
            _ = self?.apply(.init(to: pose, progress: 1))
        }
        animation.isManualHitTestingEnabled = true
        animator = animation
        recordLiftLifecycle("create id=\(identity),duration=0.12")
        animation.addCompletion { [weak self] position in
            self?.recordLiftLifecycle("completion id=\(identity),position=\(position.rawValue),identityMatches=\(self?.animationIdentity == identity)")
            guard let self, self.animationIdentity == identity else { return }
            self.animationIdentity = nil
            self.animator = nil
            self.retainsAnimationMask = false
            self.updateCrop()
            completion(position == .end)
        }
        animation.startAnimation()
        recordLiftLifecycle("started id=\(identity),state=\(animation.state.rawValue),running=\(animation.isRunning)")
    }

    private func recordLiftLifecycle(_ event: @autoclosure () -> String) {
#if DEBUG
        guard recordsLiftLifecycleForTesting else { return }
        liftLifecycleForTesting.append("\(ProcessInfo.processInfo.systemUptime):\(event())")
        if liftLifecycleForTesting.count > 24 { liftLifecycleForTesting.removeFirst(liftLifecycleForTesting.count - 24) }
#endif
    }

    override var childForStatusBarStyle: UIViewController? { contentController }
    override var childForStatusBarHidden: UIViewController? { contentController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { contentController }
}

@MainActor
private final class SurfaceHitView: UIView {
    weak var surfaceView: SurfaceClipView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let surfaceView else { return nil }
        if surfaceView.onActivate == nil {
            // The retained controller still fills the viewport after Sidebar
            // translation. Its empty strip must pass through to the Rail below.
            guard surfaceView.point(inside: surfaceView.visiblePoint(fromParent: point), with: event) else { return nil }
            return super.hitTest(point, with: event)
        }
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
              !surfaceView.isHidden, (surfaceView.layer.presentation()?.opacity ?? surfaceView.layer.opacity) > 0.01,
              self.point(inside: point, with: event) else { return nil }
        // UIKit's model transform already points at the destination. Route new
        // settlement touches through the still-visible transform and mask instead.
        let local = surfaceView.visiblePoint(fromParent: point)
        return surfaceView.point(inside: local, with: event) ? surfaceView : nil
    }
}

@MainActor
final class SurfaceClipView: UIView {
    var visibleRect: CGRect? { didSet { updateCurrentEdge(replacesPresentation: true) } }
    var onActivate: (() -> Bool)?
    private var touchOrigin: CGPoint?
    private var touchMoved = false
    private let currentEdge = CAShapeLayer()
    private var edgeRequested = false
    private var edgeRect = CGRect.null
    private var edgeRadius: CGFloat = -1
    private static let edgeAnimationKey = "zen-current-edge-crop"

    override init(frame: CGRect) {
        super.init(frame: frame)
        currentEdge.name = "zen-current-card-edge"
        currentEdge.fillColor = nil
        currentEdge.lineWidth = 0.75
        currentEdge.zPosition = 1
        currentEdge.isHidden = true
        layer.addSublayer(currentEdge)
        updateEdgeColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: SurfaceClipView, _: UITraitCollection) in view.updateEdgeColor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var currentEdgeVisible: Bool { !currentEdge.isHidden && currentEdge.opacity > 0 }

    func setCurrentEdgeVisible(_ visible: Bool) {
        edgeRequested = visible
        updateCurrentEdge()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCurrentEdge()
    }

    private func updateEdgeColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentEdge.strokeColor = UIColor.label.resolvedColor(with: traitCollection)
            .withAlphaComponent(0.14).cgColor
        CATransaction.commit()
    }

    private func updateCurrentEdge(replacesPresentation: Bool = false) {
        let rect = visibleRect ?? bounds
        let radius = mask?.layer.cornerRadius ?? layer.cornerRadius
        let show = edgeRequested && radius > 0 && rect.width > 0 && rect.height > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentEdge.frame = bounds
        currentEdge.isHidden = !show
        guard show else {
            currentEdge.removeAnimation(forKey: Self.edgeAnimationKey)
            edgeRect = .null
            edgeRadius = -1
            CATransaction.commit()
            return
        }
        let duration = UIView.inheritedAnimationDuration
        if replacesPresentation && duration == 0 {
            currentEdge.removeAnimation(forKey: Self.edgeAnimationKey)
        }
        guard edgeRect != rect || edgeRadius != radius else {
            CATransaction.commit()
            return
        }
        let inset = currentEdge.lineWidth / 2
        let path = UIBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, radius - inset)).cgPath
        let previous = (currentEdge.presentation() as? CAShapeLayer)?.path ?? currentEdge.path
        currentEdge.removeAnimation(forKey: Self.edgeAnimationKey)
        currentEdge.path = path
        edgeRect = rect
        edgeRadius = radius
        // Browse animates the native crop inside this same UIView animation block.
        // Ordinary gesture/cancellation samples replace the path without residual work.
        if duration > 0, let previous {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = previous
            animation.toValue = path
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            currentEdge.add(animation, forKey: Self.edgeAnimationKey)
        }
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = touches.first?.location(in: window)
        touchMoved = touches.count != 1
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recordMovement(touches)
        super.touchesMoved(touches, with: event)
    }

    private func recordMovement(_ touches: Set<UITouch>) {
        guard let origin = touchOrigin, let point = touches.first?.location(in: window) else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > 8 { touchMoved = true }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = nil
        touchMoved = true
        super.touchesCancelled(touches, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if onActivate != nil {
            let visibleLayer = layer.presentation() ?? layer
            let visibleMask = visibleLayer.mask ?? mask?.layer
            let rect = visibleMask?.frame ?? visibleRect ?? bounds
            let shape = visibleMask ?? visibleLayer
            return Self.roundedPath(rect: rect, radius: shape.cornerRadius,
                corners: shape.maskedCorners).contains(point)
        }
        guard let visibleRect else { return true }
        let shape = mask?.layer ?? layer
        return Self.roundedPath(rect: visibleRect, radius: shape.cornerRadius,
            corners: shape.maskedCorners).contains(point)
    }

    private static func roundedPath(rect: CGRect, radius: CGFloat, corners mask: CACornerMask) -> UIBezierPath {
        var corners: UIRectCorner = []
        if mask.contains(.layerMinXMinYCorner) { corners.insert(.topLeft) }
        if mask.contains(.layerMaxXMinYCorner) { corners.insert(.topRight) }
        if mask.contains(.layerMinXMaxYCorner) { corners.insert(.bottomLeft) }
        if mask.contains(.layerMaxXMaxYCorner) { corners.insert(.bottomRight) }
        return UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        recordMovement(touches)
        if !touchMoved, let point = touches.first?.location(in: superview),
           self.point(inside: visiblePoint(fromParent: point), with: event) {
            _ = onActivate?()
        }
        touchOrigin = nil
        super.touchesEnded(touches, with: event)
    }

    func visiblePoint(fromParent point: CGPoint) -> CGPoint {
        let visibleLayer = layer.presentation() ?? layer
        return visibleLayer.convert(point, from: visibleLayer.superlayer ?? superview?.layer)
    }

    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
    @objc func activateReturn() -> Bool { accessibilityActivate() }
}

@MainActor
final class SurfaceHostingController<Content: View>: UIHostingController<Content> {
    var onContentLayout: (() -> Void)?
    var suspendsContainerInsets = false
    private var containerInsets: UIEdgeInsets?
    private var isAdjustingInsets = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onContentLayout?()
    }

    func preserveContainerSafeArea(_ insets: UIEdgeInsets) {
        containerInsets = insets
        reconcileInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        reconcileInsets()
    }

    private func reconcileInsets() {
        guard !suspendsContainerInsets, let target = containerInsets, !isAdjustingInsets else { return }
        let current = view.safeAreaInsets
        let added = additionalSafeAreaInsets
        // UIKit recalculates inherited insets from the transformed child's placement.
        // Keep the untransformed container's layout safe area; keyboard handling remains
        // the hosting controller's native SwiftUI path, independent of this correction.
        let corrected = UIEdgeInsets(top: added.top + target.top - current.top,
                                     left: added.left + target.left - current.left,
                                     bottom: added.bottom + target.bottom - current.bottom,
                                     right: added.right + target.right - current.right)
        guard abs(corrected.top - added.top) > 0.01 || abs(corrected.left - added.left) > 0.01
            || abs(corrected.bottom - added.bottom) > 0.01 || abs(corrected.right - added.right) > 0.01 else { return }
        isAdjustingInsets = true
        additionalSafeAreaInsets = corrected
        isAdjustingInsets = false
    }
}
