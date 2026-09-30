import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SurfaceLiftController {
    private(set) var state = SurfaceLiftState()
    private(set) var overlayPresented = false
    private(set) var retainsAppSpaceViewport = false
    private(set) var splitTargetingVisible = false
    private(set) var splitTargetSlot: SplitDropSlot?
    private(set) var splitTopFrame: CGRect?
    private(set) var splitBottomFrame: CGRect?
    private(set) var splitGuideFrame: CGRect?
    private(set) var lastSplitDropIntent: SplitDropIntent?
    private var selectedSources: Set<String> = []
    var minimumCardSize = CGSize(width: 220, height: 300)
    @ObservationIgnored private var hostID: ObjectIdentifier?
    @ObservationIgnored private var target: SurfaceGeometry.Pose?
    @ObservationIgnored private var resolveTarget: ((CGSize) -> SurfaceGeometry.Pose?)?
    @ObservationIgnored private var present: ((CGFloat) -> Bool)?
    @ObservationIgnored private var presentSplit: ((SurfaceGeometry.Pose) -> Bool)?
    @ObservationIgnored private var splitSample: ((CGPoint) -> (point: CGPoint, size: CGSize, safeArea: UIEdgeInsets)?)?
    @ObservationIgnored private var animate: ((SurfaceLiftState.Settlement, Bool) -> Void)?
    @ObservationIgnored private var capture: (() -> Double)?
    @ObservationIgnored private var cancel: (() -> Void)?
    @ObservationIgnored private var interaction: ((SurfaceLiftState.Phase) -> Void)?
    @ObservationIgnored private var presentedOverlay: (() -> Bool)?
    @ObservationIgnored private var detach: (() -> Void)?

    @ObservationIgnored private var enterPreview: (() -> Bool)?
    @ObservationIgnored private var prepareFull: (() async -> Bool)?
    @ObservationIgnored private var commitFull: (() -> Bool)?
    @ObservationIgnored private var cancelPreparation: (() -> Void)?
    @ObservationIgnored private var previewIsPresented: (() -> Bool)?
    @ObservationIgnored private var cardLabel: (() -> String)?
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    @ObservationIgnored private var returnOperation: UUID?
    @ObservationIgnored private var returnNeedsHandoff = false
    @ObservationIgnored private var pendingViewportReturn: (() -> Void)?
    @ObservationIgnored private var splitTargeting = SplitTargetingState()
    @ObservationIgnored private var splitPreviewPose: SurfaceGeometry.Pose?
    @ObservationIgnored private var splitFinalPose: SurfaceGeometry.Pose?
    @ObservationIgnored private var splitReturnPose: SurfaceGeometry.Pose?
    @ObservationIgnored private var splitActivationProgress = 0.0
    @ObservationIgnored private var sourceConversationID: String?
    @ObservationIgnored private var splitDropConsumer: ((SplitDropIntent) -> Bool)?
    @ObservationIgnored private var splitConverged: ((SplitDropIntent) -> Void)?
    @ObservationIgnored private var acceptedSplitIntent: SplitDropIntent?
    @ObservationIgnored private var splitWorkspacePresented = false
    @ObservationIgnored var onSplitTargetEntry: () -> Void = {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // onDrop is admission only. A consumer that changes Workspace geometry
    // must wait for onConverged, after the retained native Surface has settled.
    func configureSplit(onDrop: ((SplitDropIntent) -> Bool)?,
                        onConverged: ((SplitDropIntent) -> Void)? = nil) {
        splitDropConsumer = onDrop
        splitConverged = onConverged
    }

    func setSplitWorkspacePresented(_ presented: Bool) {
        splitWorkspacePresented = presented
    }

    func configurePreview(enter: @escaping () -> Bool, prepare: @escaping () async -> Bool,
                          commit: @escaping () -> Bool, cancel: @escaping () -> Void,
                          isPresented: @escaping () -> Bool, label: @escaping () -> String) {
        enterPreview = enter
        prepareFull = prepare
        commitFull = commit
        cancelPreparation = cancel
        previewIsPresented = isPresented
        cardLabel = label
    }

    var hasSelection: Bool { !selectedSources.isEmpty }
    var isPreparingReturn: Bool { returnOperation != nil }

    func bind<Content: View>(_ host: ConversationSurfaceViewController<Content>) {
        guard hostID != ObjectIdentifier(host) else { return }
        invalidate()
        detach?()
        host.liftController?.unbind(host)
        host.loadViewIfNeeded()
        hostID = ObjectIdentifier(host)
        host.liftController = self
        detach = { [weak host] in host?.onViewportChanged = nil; host?.liftController = nil }
        host.onViewportChanged = { [weak self] in
            guard let self else { return }
            if let handoff = self.pendingViewportReturn {
                self.pendingViewportReturn = nil
                handoff()
            } else { self.invalidate() }
        }
        resolveTarget = { [weak self, weak host] minimum in
            guard let host else { return nil }
            let workspace = self?.splitWorkspacePresented == true ? host.view.window : nil
            let size = workspace?.bounds.size ?? host.view.bounds.size
            let safeArea = workspace?.safeAreaInsets ?? host.view.safeAreaInsets
            guard let placement = AppSpaceGeometry.resolve(size: size,
                    safeArea: safeArea, historyIDs: [], current: .newConversation,
                    minimumCardSize: minimum)?.cards.last else { return nil }
            let frame = workspace.map { host.view.convert(placement.frame, from: $0) } ?? placement.frame
            return SurfaceLiftGeometry.targetPose(size: host.view.bounds.size, safeArea: host.view.safeAreaInsets,
                card: frame, cornerRadius: placement.cornerRadius, constrainedToSafeArea: workspace == nil)
        }
        present = { [weak self, weak host] progress in
            guard let host else { return false }
            return host.apply(.init(to: self?.target ?? .full, progress: progress))
        }
        presentSplit = { [weak host] pose in host?.apply(.init(to: pose, progress: 1)) ?? false }
        splitSample = { [weak host] point in
            guard let host, let window = host.view.window else { return nil }
            return (host.view.convert(point, from: window), host.view.bounds.size, host.view.safeAreaInsets)
        }
        cancel = { [weak host] in
            host?.deletionInteraction?.cancel()
            host?.browseInteraction?.cancel()
            host?.resetLiftPresentation()
        }
        capture = { [weak self, weak host] in
            guard let host, let target = self?.splitReturnPose ?? self?.target else { return 0 }
            return host.captureLiftProgress(target: target)
        }
        interaction = { [weak self, weak host] phase in
            host?.setLiftInteraction(phase) { [weak self] in self?.returnToFull() ?? false }
            host?.surfaceView.accessibilityLabel = self?.cardLabel?() ?? "当前会话"
        }
        presentedOverlay = { [weak host] in host?.hasPresentedOverlay ?? true }
        animate = { [weak self, weak host] settlement, animated in
            guard let self, let host, let target = self.splitReturnPose ?? self.target else {
                self?.invalidate(); return
            }
            let binding = self.hostID
            if settlement.destination == .split {
                host.convergeLift(to: target, animated: animated) { [weak self] finished in
                    guard let self, self.hostID == binding,
                          self.state.complete(settlement, finished: finished) else { return }
                    if !finished { self.invalidate(); return }
                    self.splitReturnPose = target
                    self.updatePresentation()
                    if let intent = self.acceptedSplitIntent {
                        self.acceptedSplitIntent = nil
                        self.splitConverged?(intent)
                    }
                }
                return
            }
            let handoff = settlement.destination == .full && self.returnNeedsHandoff
            let endpoint = settlement.destination == .card ? 1.0 : (handoff ? 0.35 : 0)
            host.animateLift(target: target, from: settlement.startProgress,
                to: endpoint, animated: animated) { [weak self, weak host] finished in
                guard let self, let host, self.hostID == binding,
                      self.state.pendingSettlement == settlement else { return }
                if handoff {
                    if finished, self.splitWorkspacePresented, self.retainsAppSpaceViewport,
                       let window = host.view.window {
                        let frame = host.surfaceView.convert(host.surfaceView.visibleRect ?? host.surfaceView.bounds,
                                                             to: window)
                        let radius = host.presentation.cornerRadius * host.presentation.scale
                        guard self.commitFull?() == true else { self.invalidate(); return }
                        self.returnNeedsHandoff = false
                        // Rebase the same native Surface at the content handoff. The
                        // final segment then uses the restored Pane's logical viewport.
                        self.pendingViewportReturn = { [weak self, weak host, weak window] in
                            guard let self, let host, let window, self.hostID == binding,
                                  self.state.pendingSettlement == settlement,
                                  let pose = SurfaceLiftGeometry.targetPose(size: host.view.bounds.size,
                                    safeArea: host.view.safeAreaInsets,
                                    card: host.view.convert(frame, from: window), cornerRadius: radius,
                                    constrainedToSafeArea: false) else { self?.invalidate(); return }
                            self.target = pose
                            host.animateLift(target: pose, from: 1, to: 0, animated: animated) { [weak self] finished in
                                guard let self, self.hostID == binding,
                                      self.state.complete(settlement, finished: finished) else { return }
                                self.updatePresentation()
                            }
                        }
                        self.retainsAppSpaceViewport = false
                        return
                    }
                    guard finished, self.commitFull?() == true else { self.invalidate(); return }
                    self.returnNeedsHandoff = false
                    // Preview occupies the first segment. The same Surface hosts
                    // live content only for the final segment, never a miniature editor.
                    host.animateLift(target: target, from: endpoint, to: 0, animated: animated) { [weak self] finished in
                        guard let self, self.hostID == binding,
                              self.state.complete(settlement, finished: finished) else { return }
                        self.retainsAppSpaceViewport = false
                        self.updatePresentation()
                    }
                } else {
                    guard self.state.complete(settlement, finished: finished) else { return }
                    self.splitReturnPose = nil
                    if self.state.phase == .card, self.enterPreview?() == false {
                        _ = self.returnToFull(animated: animated)
                        return
                    }
                    self.retainsAppSpaceViewport = self.state.phase == .card
                    self.updatePresentation()
                }
            }
        }
        updatePresentation()
    }

    func unbind<Content: View>(_ host: ConversationSurfaceViewController<Content>) {
        guard hostID == ObjectIdentifier(host) else { return }
        invalidate()
        host.onViewportChanged = nil
        host.liftController = nil
        hostID = nil
        resolveTarget = nil
        present = nil
        presentSplit = nil
        splitSample = nil
        animate = nil
        capture = nil
        cancel = nil
        interaction = nil
        presentedOverlay = nil
        detach = nil
    }

    private func guarded(_ input: SurfaceLiftEligibility) -> SurfaceLiftEligibility {
        var result = input
        result.selectionActive = result.selectionActive || hasSelection
        result.overlayPresented = result.overlayPresented || overlayPresented || (presentedOverlay?() ?? true)
        return result
    }
    func canArm(_ input: SurfaceLiftEligibility) -> Bool {
        state.phase == .full
            && guarded(input).allowsLift && resolveTarget?(minimumCardSize) != nil
    }
    func arm(_ input: SurfaceLiftEligibility, conversationID: String? = nil) -> Bool {
        guard canArm(input), let pose = resolveTarget?(minimumCardSize) else { return false }
        clearSplitTargeting()
        lastSplitDropIntent = nil
        acceptedSplitIntent = nil
        sourceConversationID = conversationID
        target = pose
        let armed = state.arm(guarded(input))
        updatePresentation()
        return armed
    }
    func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility,
              locationInWindow: CGPoint? = nil) -> Bool {
        guard state.phase == .armed || state.phase == .lifting else { return false }
        let dragged = state.drag(upwardDistance: upwardDistance, eligibility: guarded(eligibility))
        if dragged, state.phase == .lifting, !splitWorkspacePresented, sourceConversationID != nil,
           let locationInWindow, let sample = splitSample?(locationInWindow) {
            updateSplitTargeting(upwardDistance: upwardDistance, sample: sample)
        } else {
            clearSplitTargeting()
        }
        updatePresentation()
        return dragged
    }
    @discardableResult
    func end(cancelled: Bool = false, animated: Bool = true) -> SurfaceLiftState.Settlement? {
        guard state.phase == .armed || state.phase == .lifting else { return nil }
        let slot = splitTargeting.end(cancelled: cancelled)
        let intent = slot.flatMap { slot in sourceConversationID.map { SplitDropIntent(conversationID: $0, slot: slot) } }
        if let intent { lastSplitDropIntent = intent }
        let hadSplitPreview = splitPreviewPose != nil
        let finalPose = splitFinalPose
        if hadSplitPreview { splitReturnPose = splitPreviewPose }
        clearSplitTargeting()
        sourceConversationID = nil
        let accepted = intent.flatMap { splitDropConsumer?($0) } ?? false
        if accepted, let finalPose {
            splitReturnPose = finalPose
            acceptedSplitIntent = intent
        }
        let settlement = accepted && finalPose != nil
            ? state.endForSplit() : state.end(cancelled: cancelled || hadSplitPreview)
        interaction?(state.phase)
        if let settlement { animate?(settlement, animated) } else { updatePresentation() }
        return settlement
    }
    @discardableResult
    func returnToFull(animated: Bool = true) -> Bool {
        guard !overlayPresented, presentedOverlay?() != true else { return false }
        guard state.phase == .card || state.phase == .split || state.phase == .settling || state.phase == .lifting else { return false }
        if previewIsPresented?() == true, state.phase == .card, let prepareFull {
            if returnOperation != nil { return true }
            let operation = UUID()
            let binding = hostID
            returnOperation = operation
            returnTask = Task { [weak self] in
                let ready = await prepareFull()
                guard let self, self.returnOperation == operation else { return }
                self.returnTask = nil
                self.returnOperation = nil
                guard ready, !Task.isCancelled, self.hostID == binding, self.state.phase == .card else {
                    self.cancelPreparation?()
                    self.updatePresentation()
                    return
                }
                self.returnNeedsHandoff = true
                self.startReturn(animated: animated)
            }
            return true
        }
        // Repeated Return input must not keep replacing a Full-bound settlement
        // and delay restoration of the retained editor indefinitely.
        if animated, state.phase == .settling, state.pendingSettlement?.destination == .full { return true }
        startReturn(animated: animated)
        return true
    }

    private func startReturn(animated: Bool) {
        guard let settlement = state.requestReturn(visibleProgress: capture?()) else { return }
        acceptedSplitIntent = nil
        interaction?(state.phase)
        animate?(settlement, animated)
    }

    private func cancelReturn() {
        pendingViewportReturn = nil
        returnOperation = nil
        returnTask?.cancel()
        returnTask = nil
        returnNeedsHandoff = false
        cancelPreparation?()
    }

    func resetForConversationChange() {
        retainsAppSpaceViewport = false
        cancelReturn()
        clearSplitTargeting()
        lastSplitDropIntent = nil
        acceptedSplitIntent = nil
        splitReturnPose = nil
        sourceConversationID = nil
        cancel?()
        state.interrupt()
        updatePresentation()
        target = nil
    }

    func invalidate() {
        cancelReturn()
        clearSplitTargeting()
        acceptedSplitIntent = nil
        splitReturnPose = nil
        sourceConversationID = nil
        cancel?()
        if previewIsPresented?() == true {
            state.restoreCard()
            retainsAppSpaceViewport = true
            target = resolveTarget?(minimumCardSize)
            updatePresentation()
            return
        }
        retainsAppSpaceViewport = false
        guard state.phase != .full || state.progress != 0 || target != nil else { return }
        state.interrupt()
        updatePresentation()
        target = nil
    }
    func refreshCardAccessibility() { interaction?(state.phase) }

    private func updatePresentation() {
        if let splitPreviewPose { _ = presentSplit?(splitPreviewPose) }
        else if state.phase == .split, let splitReturnPose { _ = presentSplit?(splitReturnPose) }
        else { _ = present?(CGFloat(state.progress)) }
        interaction?(state.phase)
    }

    private func updateSplitTargeting(upwardDistance: Double,
                                      sample: (point: CGPoint, size: CGSize, safeArea: UIEdgeInsets)) {
        guard upwardDistance.isFinite,
              let top = SplitTargetingGeometry.preview(slot: .top, progress: 1,
                  size: sample.size, safeArea: sample.safeArea),
              let bottom = SplitTargetingGeometry.preview(slot: .bottom, progress: 1,
                  size: sample.size, safeArea: sample.safeArea) else {
            clearSplitTargeting()
            return
        }
        // The original 220 pt Card gesture remains intact. Continuing beyond it
        // reveals Split targets; values are first-pass calibration for device review.
        let progress = min(1, max(0, (upwardDistance - 220) / 80))
        splitActivationProgress = max(splitActivationProgress, progress)
        let viewport = CGRect(x: sample.safeArea.left, y: sample.safeArea.top,
                              width: sample.size.width - sample.safeArea.left - sample.safeArea.right,
                              height: sample.size.height - sample.safeArea.top - sample.safeArea.bottom)
        let update = splitTargeting.update(point: sample.point, viewport: viewport,
                                           liftProgress: splitActivationProgress)
        splitTargetingVisible = splitActivationProgress > 0
        splitTargetSlot = update.slot
        splitTopFrame = top.paneFrame
        splitBottomFrame = bottom.paneFrame
        splitGuideFrame = top.guideFrame
        if update.enteredTarget { onSplitTargetEntry() }
        guard let slot = update.slot,
              let preview = SplitTargetingGeometry.preview(slot: slot, progress: 0.85,
                  size: sample.size, safeArea: sample.safeArea), let target else {
            splitPreviewPose = nil
            splitFinalPose = nil
            return
        }
        splitFinalPose = SplitTargetingGeometry.preview(slot: slot, progress: 1,
            size: sample.size, safeArea: sample.safeArea)?.pose
        let blend = CGFloat(splitActivationProgress)
        func between(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * blend }
        var pose = SurfaceGeometry.Pose(scale: between(target.scale, preview.pose.scale),
            translation: CGSize(width: between(target.translation.width, preview.pose.translation.width),
                                height: between(target.translation.height, preview.pose.translation.height)),
            cornerRadius: between(target.cornerRadius, preview.pose.cornerRadius))
        pose.clipFraction = CGSize(width: between(target.clipFraction.width, preview.pose.clipFraction.width),
                                   height: between(target.clipFraction.height, preview.pose.clipFraction.height))
        splitPreviewPose = pose.isValid ? pose : nil
    }

    private func clearSplitTargeting() {
        splitTargeting.reset()
        splitTargetingVisible = false
        splitTargetSlot = nil
        splitTopFrame = nil
        splitBottomFrame = nil
        splitGuideFrame = nil
        splitPreviewPose = nil
        splitFinalPose = nil
        splitActivationProgress = 0
    }
    func setOverlayPresented(_ value: Bool) {
        guard overlayPresented != value else { return }
        overlayPresented = value
        if value { invalidate() }
    }
    func setSelection(sourceID: String, active: Bool) {
        guard selectedSources.contains(sourceID) != active else { return }
        if active { selectedSources.insert(sourceID) } else { selectedSources.remove(sourceID) }
        if active { invalidate() }
    }
}
