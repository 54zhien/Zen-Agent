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

    var hasSelection: Bool { !selectedSources.isEmpty }

    func bind<Content: View>(_ host: ConversationSurfaceViewController<Content>) {
        guard hostID != ObjectIdentifier(host) else { return }
        invalidate()
        detach?()
        host.liftController?.unbind(host)
        host.loadViewIfNeeded()
        hostID = ObjectIdentifier(host)
        host.liftController = self
        detach = { [weak host] in host?.onViewportChanged = nil; host?.liftController = nil }
        host.onViewportChanged = { [weak self] in self?.invalidate() }
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
        cancel = { [weak host] in host?.resetLiftPresentation() }
        capture = { [weak self, weak host] in
            guard let host, let target = self?.target else { return 0 }
            return host.captureLiftProgress(target: target)
        }
        interaction = { [weak self, weak host] phase in
            host?.setLiftInteraction(phase) { [weak self] in self?.returnToFull() ?? false }
        }
        presentedOverlay = { [weak host] in host?.hasPresentedOverlay ?? true }
        animate = { [weak self, weak host] settlement, animated in
            guard let self, let host, let target = self.target else { self?.invalidate(); return }
            let binding = self.hostID
            host.animateLift(target: target, from: settlement.startProgress,
                to: settlement.destination == .card ? 1 : 0, animated: animated) { [weak self] finished in
                guard let self, self.hostID == binding, self.state.complete(settlement, finished: finished) else { return }
                self.updatePresentation()
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
    func arm(_ input: SurfaceLiftEligibility, at point: CGPoint = .zero) -> Bool {
        guard canArm(input), let pose = resolveTarget?(minimumCardSize) else { return false }
        target = pose
        let armed = state.arm(guarded(input))
        updatePresentation()
        return armed
    }
    func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility) -> Bool {
        let dragged = state.drag(upwardDistance: upwardDistance, eligibility: guarded(eligibility))
        updatePresentation()
        return dragged
    }
    @discardableResult
    func end(cancelled: Bool = false, animated: Bool = true) -> SurfaceLiftState.Settlement? {
        let settlement = state.end(cancelled: cancelled)
        interaction?(state.phase)
        if let settlement { animate?(settlement, animated) } else { updatePresentation() }
        return settlement
    }
    @discardableResult
    func returnToFull(animated: Bool = true) -> Bool {
        guard let settlement = state.requestReturn(visibleProgress: capture?()) else { return false }
        interaction?(state.phase)
        animate?(settlement, animated)
        return true
    }
    func invalidate() {
        cancel?()
        guard state.phase != .full || state.progress != 0 || target != nil else { return }
        state.interrupt()
        updatePresentation()
        target = nil
    }
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
