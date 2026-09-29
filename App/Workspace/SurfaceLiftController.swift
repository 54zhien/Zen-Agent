import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SurfaceLiftController {
    private(set) var state = SurfaceLiftState()
    private(set) var overlayPresented = false
    private var selectedSources: Set<String> = []
    var minimumCardSize = CGSize(width: 220, height: 300)
    @ObservationIgnored private var hostID: ObjectIdentifier?
    @ObservationIgnored private var target: SurfaceGeometry.Pose?
    @ObservationIgnored private var resolveTarget: ((CGSize) -> SurfaceGeometry.Pose?)?
    @ObservationIgnored private var present: ((CGFloat) -> Bool)?
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
#if DEBUG
        AppSpaceBrowseController.trace("bind rebind=\(hostID != nil)")
#endif
        invalidate()
        detach?()
        host.liftController?.unbind(host)
        host.loadViewIfNeeded()
        hostID = ObjectIdentifier(host)
        host.liftController = self
        detach = { [weak host] in host?.onViewportChanged = nil; host?.liftController = nil }
        host.onViewportChanged = { [weak self] in
#if DEBUG
            AppSpaceBrowseController.trace("native viewport invalidation")
#endif
            self?.invalidate()
        }
        resolveTarget = { [weak host] minimum in
            guard let host,
                  let placement = AppSpaceGeometry.resolve(size: host.view.bounds.size,
                    safeArea: host.view.safeAreaInsets, historyIDs: [], current: .newConversation,
                    minimumCardSize: minimum)?.cards.last else { return nil }
            return SurfaceLiftGeometry.targetPose(size: host.view.bounds.size, safeArea: host.view.safeAreaInsets,
                card: placement.frame, cornerRadius: placement.cornerRadius)
        }
        present = { [weak self, weak host] progress in
            guard let host else { return false }
            return host.apply(.init(to: self?.target ?? .full, progress: progress))
        }
        cancel = { [weak host] in host?.browseInteraction?.cancel(); host?.resetLiftPresentation() }
        capture = { [weak self, weak host] in
            guard let host, let target = self?.target else { return 0 }
            return host.captureLiftProgress(target: target)
        }
        interaction = { [weak self, weak host] phase in
            host?.setLiftInteraction(phase) { [weak self] in self?.returnToFull() ?? false }
            host?.surfaceView.accessibilityLabel = self?.cardLabel?() ?? "当前会话"
        }
        presentedOverlay = { [weak host] in host?.hasPresentedOverlay ?? true }
        animate = { [weak self, weak host] settlement, animated in
            guard let self, let host, let target = self.target else { self?.invalidate(); return }
            let binding = self.hostID
            let handoff = settlement.destination == .full && self.returnNeedsHandoff
            let endpoint = settlement.destination == .card ? 1.0 : (handoff ? 0.35 : 0)
            host.animateLift(target: target, from: settlement.startProgress,
                to: endpoint, animated: animated) { [weak self, weak host] finished in
                guard let self, let host, self.hostID == binding,
                      self.state.pendingSettlement == settlement else { return }
                if handoff {
#if DEBUG
                    AppSpaceBrowseController.trace("handoff completion finished=\(finished)")
#endif
                    guard finished, self.commitFull?() == true else { self.invalidate(); return }
                    self.returnNeedsHandoff = false
                    // Preview occupies the first segment. The same Surface hosts
                    // live content only for the final segment, never a miniature editor.
                    host.animateLift(target: target, from: endpoint, to: 0, animated: animated) { [weak self] finished in
                        guard let self, self.hostID == binding,
                              self.state.complete(settlement, finished: finished) else { return }
                        self.updatePresentation()
                    }
                } else {
                    guard self.state.complete(settlement, finished: finished) else { return }
                    if self.state.phase == .card, self.enterPreview?() == false {
                        _ = self.returnToFull(animated: animated)
                        return
                    }
                    self.updatePresentation()
                }
            }
        }
        updatePresentation()
    }

    func unbind<Content: View>(_ host: ConversationSurfaceViewController<Content>) {
        guard hostID == ObjectIdentifier(host) else { return }
#if DEBUG
        AppSpaceBrowseController.trace("unbind")
#endif
        invalidate()
        host.onViewportChanged = nil
        host.liftController = nil
        hostID = nil
        resolveTarget = nil
        present = nil
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
        state.phase == .full && guarded(input).allowsLift && resolveTarget?(minimumCardSize) != nil
    }
    func arm(_ input: SurfaceLiftEligibility) -> Bool {
        guard canArm(input), let pose = resolveTarget?(minimumCardSize) else { return false }
        target = pose
        let armed = state.arm(guarded(input))
        updatePresentation()
        return armed
    }
    func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility) -> Bool {
        guard state.phase == .armed || state.phase == .lifting else { return false }
        let dragged = state.drag(upwardDistance: upwardDistance, eligibility: guarded(eligibility))
        updatePresentation()
        return dragged
    }
    @discardableResult
    func end(cancelled: Bool = false, animated: Bool = true) -> SurfaceLiftState.Settlement? {
        guard state.phase == .armed || state.phase == .lifting else { return nil }
        let settlement = state.end(cancelled: cancelled)
        interaction?(state.phase)
        if let settlement { animate?(settlement, animated) } else { updatePresentation() }
        return settlement
    }
    @discardableResult
    func returnToFull(animated: Bool = true) -> Bool {
        guard state.phase == .card || state.phase == .settling || state.phase == .lifting else { return false }
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
        interaction?(state.phase)
        animate?(settlement, animated)
    }

    private func cancelReturn() {
        returnOperation = nil
        returnTask?.cancel()
        returnTask = nil
        returnNeedsHandoff = false
        cancelPreparation?()
    }

    func resetForConversationChange() {
        cancelReturn()
        cancel?()
        state.interrupt()
        updatePresentation()
        target = nil
    }

    func invalidate() {
#if DEBUG
        AppSpaceBrowseController.trace("invalidate phase=\(state.phase) preview=\(previewIsPresented?() == true)")
#endif
        cancelReturn()
        cancel?()
        if previewIsPresented?() == true {
            state.restoreCard()
            target = resolveTarget?(minimumCardSize)
            updatePresentation()
            return
        }
        guard state.phase != .full || state.progress != 0 || target != nil else { return }
        state.interrupt()
        updatePresentation()
        target = nil
    }
    func refreshCardAccessibility() { interaction?(state.phase) }

    private func updatePresentation() {
        _ = present?(CGFloat(state.progress))
        interaction?(state.phase)
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
