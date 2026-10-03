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
    let content: Content

    init(request: SurfaceGeometry.Request = .full, liftController: SurfaceLiftController? = nil,
         browseController: AppSpaceBrowseController? = nil,
         deleteAction: AppSpaceCardDeletionInteraction.Commit? = nil,
         isDeletionPending: (@MainActor (String) -> Bool)? = nil,
         isWorkspaceVisible: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.request = request
        self.liftController = liftController
        self.browseController = browseController
        self.deleteAction = deleteAction
        self.isDeletionPending = isDeletionPending
        self.isWorkspaceVisible = isWorkspaceVisible
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ConversationSurfaceViewController<Content> {
        let controller = ConversationSurfaceViewController(content: content, request: request)
        liftController?.bind(controller)
        controller.bindBrowse(browseController)
        controller.bindDeletion(deleteAction, isPending: isDeletionPending)
        controller.setWorkspaceVisible(isWorkspaceVisible)
        return controller
    }

    func updateUIViewController(_ controller: ConversationSurfaceViewController<Content>, context: Context) {
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
        controller.setWorkspaceVisible(isWorkspaceVisible)
    }

    static func dismantleUIViewController(_ controller: ConversationSurfaceViewController<Content>,
                                         coordinator: Void) {
        controller.unbindDeletion()
        controller.unbindBrowse()
        controller.liftController?.unbind(controller)
    }
}

@MainActor
final class ConversationSurfaceViewController<Content: View>: UIViewController {
    let contentController: SurfaceHostingController<Content>
    let surfaceView = SurfaceClipView()
    private(set) var presentation = SurfaceGeometry.Presentation.full
    private var request = SurfaceGeometry.Request.full
    weak var liftController: SurfaceLiftController?
    private(set) var browseInteraction: AppSpaceBrowseInteraction?
    private(set) var deletionInteraction: AppSpaceCardDeletionInteraction?
    var onViewportChanged: (() -> Void)?
    private var lastViewport: CGRect?
    private var lastInsets: UIEdgeInsets?
    private let cropMask = UIView()
    private var animator: UIViewPropertyAnimator?
#if DEBUG
    // Tests pause the real animator so a busy simulator cannot skip settlement.
    var liftAnimatorForTesting: UIViewPropertyAnimator? { animator }

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
        let mounted = editors(in: contentController.view)
        var fields = ["host=\(ObjectIdentifier(self))", "phase=\(String(describing: liftController?.state.phase))",
            "visible=\(workspaceVisible)", "root=\(chain(view))",
            "contentInteraction=\(contentController.view.isUserInteractionEnabled)",
            "contentAXHidden=\(contentController.view.accessibilityElementsHidden)",
            "surfaceAX=\(surfaceView.isAccessibilityElement)", "activate=\(surfaceView.onActivate != nil)",
            "editors=\(mounted.count)", "browse=\(browseInteraction?.diagnostic ?? "none")"]
        if let editor = mounted.first, let window = view.window {
            let point = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: window)
            fields.append("editorIdentity=\(ObjectIdentifier(editor))")
            fields.append("focused=\(editor.isFirstResponder)")
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
        cropMask.backgroundColor = .black
        cropMask.layer.cornerCurve = .continuous
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Bounds and center remain independent of the presentation transform.
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if surfaceView.bounds != bounds { surfaceView.bounds = bounds }
        if surfaceView.center != center { surfaceView.center = center }
        if workspaceVisible { contentController.preserveContainerSafeArea(view.safeAreaInsets) }
        // onAppear may restore Card before a usable viewport exists. Notify the
        // first layout too, so that Card's first Return has a resolved Lift target.
        let changed = lastViewport != view.bounds || lastInsets != view.safeAreaInsets
        lastViewport = view.bounds
        lastInsets = view.safeAreaInsets
        if changed { onViewportChanged?() }
        browseInteraction?.updateViewport()
        _ = apply(request)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if workspaceVisible { contentController.preserveContainerSafeArea(view.safeAreaInsets) }
    }

    @discardableResult
    func apply(_ candidate: SurfaceGeometry.Request, force: Bool = false) -> Bool {
        guard let resolved = SurfaceGeometry.resolve(size: view.bounds.size, safeArea: view.safeAreaInsets, request: candidate) else { return false }
        request = candidate
        guard force || presentation != resolved else { updateCrop(); return true }
        presentation = resolved
        surfaceView.transform = CGAffineTransform(a: resolved.scale, b: 0, c: 0, d: resolved.scale, tx: resolved.translation.width, ty: resolved.translation.height)
        surfaceView.layer.cornerRadius = resolved.cornerRadius
        updateCrop()
        return true
    }

    private func updateCrop() {
        let fraction = presentation.clipFraction
        let cropped = fraction != CGSize(width: 1, height: 1)
        guard cropped || retainsAnimationMask else {
            surfaceView.mask = nil
            surfaceView.visibleRect = nil
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
    }

    func setLiftInteraction(_ phase: SurfaceLiftState.Phase, returnAction: @escaping () -> Bool) {
        let frozen = phase == .settling || phase == .card || phase == .split
        contentController.view.isUserInteractionEnabled = workspaceVisible && !frozen
        contentController.view.accessibilityElementsHidden = !workspaceVisible || frozen
        surfaceView.isAccessibilityElement = workspaceVisible && frozen
        surfaceView.accessibilityIdentifier = phase == .card ? "workspace-current-card" : nil
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
            surfaceView.addSubview(contentView)
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
        cancelLiftAnimation()
        _ = apply(.init(from: restingPose, to: target, progress: CGFloat(from)))
        guard animated, !UIAccessibility.isReduceMotionEnabled, abs(to - from) > 0.000001 else {
            let applied = apply(.init(from: restingPose, to: target, progress: CGFloat(to)))
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
        animation.addCompletion { [weak self] position in
            guard let self, self.animationIdentity == identity else { return }
            self.animationIdentity = nil
            self.animator = nil
            self.retainsAnimationMask = false
            self.updateCrop()
            completion(position == .end)
        }
        animation.startAnimation()
    }

    func convergeLift(to pose: SurfaceGeometry.Pose, animated: Bool,
                      completion: @escaping (Bool) -> Void) {
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
        animation.addCompletion { [weak self] position in
            guard let self, self.animationIdentity == identity else { return }
            self.animationIdentity = nil
            self.animator = nil
            self.retainsAnimationMask = false
            self.updateCrop()
            completion(position == .end)
        }
        animation.startAnimation()
    }

    override var childForStatusBarStyle: UIViewController? { contentController }
    override var childForStatusBarHidden: UIViewController? { contentController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { contentController }
}

@MainActor
private final class SurfaceHitView: UIView {
    weak var surfaceView: SurfaceClipView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let surfaceView, surfaceView.onActivate != nil else {
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
    var visibleRect: CGRect?
    var onActivate: (() -> Bool)?
    private var touchOrigin: CGPoint?
    private var touchMoved = false

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
            return UIBezierPath(roundedRect: rect,
                cornerRadius: visibleMask?.cornerRadius ?? visibleLayer.cornerRadius).contains(point)
        }
        guard let visibleRect else { return true }
        return UIBezierPath(roundedRect: visibleRect, cornerRadius: mask?.layer.cornerRadius ?? 0).contains(point)
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
    var suspendsContainerInsets = false
    private var containerInsets: UIEdgeInsets?
    private var isAdjustingInsets = false

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
