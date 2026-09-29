import SwiftUI
import UIKit

/// Native input and animation transport. The controller owns only projections;
/// the existing Surface keeps its hosting child and untransformed bounds.
@MainActor
final class AppSpaceBrowseInteraction: NSObject, UIGestureRecognizerDelegate {
    enum Direction: Equatable { case older, newer }
    let controller: AppSpaceBrowseController
    let recognizer = UIPanGestureRecognizer()
    private weak var surface: SurfaceClipView?
    private weak var coordinates: UIView?
    private let canBrowse: () -> Bool
    private let render: (AppSpaceBrowseGeometry.Card) -> Bool
    private let refreshAccessibility: () -> Void
    private var animator: UIViewPropertyAnimator?
    private var animationID: UUID?
#if DEBUG
    var animatorForTesting: UIViewPropertyAnimator? { animator }
#endif
    private var lastPhase: AppSpaceBrowseState.Phase?
    private var lastSelected: AppSpaceGeometry.Item?
    private var lastOlder: AppSpaceGeometry.Item?
    private var lastNewer: AppSpaceGeometry.Item?
    private var lastSuspended: Bool?
    private var lastCanEditMetadata: Bool?

    init(surface: SurfaceClipView, coordinates: UIView, controller: AppSpaceBrowseController,
         canBrowse: @escaping () -> Bool, render: @escaping (AppSpaceBrowseGeometry.Card) -> Bool,
         refreshAccessibility: @escaping () -> Void) {
        self.surface = surface
        self.coordinates = coordinates
        self.controller = controller
        self.canBrowse = canBrowse
        self.render = render
        self.refreshAccessibility = refreshAccessibility
        super.init()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(gestureChanged(_:)))
        surface.addGestureRecognizer(recognizer)
        controller.onChanged = { [weak self] in self?.stateChanged() }
        updateViewport()
    }

    func updateViewport() {
        guard let coordinates else { return }
        controller.updateViewport(size: coordinates.bounds.size, safeArea: coordinates.safeAreaInsets)
    }

    func updateAvailability() {
        // UIKit can still report the dismissing alert here. Keep the recognizer
        // available after logical dismissal; the delegate checks actual overlays
        // again at gesture start, so a transition cannot leave it disabled forever.
        let enabled = controller.isPresented && !controller.interactionSuspended
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    var canNavigate: Bool { canBrowse() && controller.state.phase == .idle }
    var hasNavigationActions: Bool {
        controller.isPresented && !controller.interactionSuspended && controller.state.phase == .idle
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, canBrowse(), controller.state.phase == .idle,
              controller.layout() != nil, let coordinates else { return false }
        let velocity = recognizer.velocity(in: coordinates.window ?? coordinates)
        return velocity.x.isFinite && velocity.y.isFinite && abs(velocity.x) > abs(velocity.y) * 1.1
    }

    @objc private func gestureChanged(_ pan: UIPanGestureRecognizer) {
        guard let coordinates, let layout = controller.layout() else { cancel(); return }
        let reference = coordinates.window ?? coordinates
        switch pan.state {
        case .began:
            guard canBrowse(), controller.begin() else { return }
            _ = controller.drag(displacement: Double(pan.translation(in: reference).x), travel: Double(layout.travel))
        case .changed:
            _ = controller.drag(displacement: Double(pan.translation(in: reference).x), travel: Double(layout.travel))
        case .ended:
            settle(velocity: Double(pan.velocity(in: reference).x))
        case .cancelled, .failed: cancel()
        default: break
        }
    }

    @discardableResult
    func navigate(_ direction: Direction) -> Bool {
        guard canBrowse(), controller.state.phase == .idle,
              (direction == .older ? controller.state.older : controller.state.newer) != nil,
              let layout = controller.layout(), controller.begin() else { return false }
        settle(velocity: Double(layout.travel) * (direction == .older ? 10 : -10))
        return true
    }

    private func settle(velocity: Double) {
        guard controller.state.phase == .dragging, let layout = controller.layout(),
              let from = layout.cards.first(where: { $0.item == controller.state.selected }) else { cancel(); return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        let settlement = withAnimation(animated ? .easeInOut(duration: 0.28) : nil) {
            controller.end(velocity: velocity, travel: Double(layout.travel))
        }
        guard let settlement,
              let to = controller.layout()?.cards.first(where: { $0.item == controller.state.selected }) else { cancel(); return }
        stopAnimator()
        UIView.performWithoutAnimation { _ = render(from) }
        guard animated else {
            let rendered = render(to)
            let committed = controller.complete(settlement, finished: rendered)
            announce(committed: committed)
            return
        }
        let identity = UUID()
        animationID = identity
        let animation = UIViewPropertyAnimator(duration: 0.28, curve: .easeInOut) { [weak self] in
            _ = self?.render(to)
        }
        animation.isManualHitTestingEnabled = true
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, self.animationID == identity else { return }
            self.animationID = nil
            self.animator = nil
            let committed = self.controller.complete(settlement, finished: position == .end)
            self.announce(committed: committed)
        }
        animation.startAnimation()
    }

    func cancel() {
        stopAnimator()
        withAnimation(nil) { controller.cancel() }
    }

    func unbind() {
        cancel()
        controller.onChanged = nil
        surface?.removeGestureRecognizer(recognizer)
    }

    private func stopAnimator() {
        animationID = nil
        animator?.stopAnimation(true)
        animator = nil
    }

    private func announce(committed: Bool) {
        if committed {
            UIAccessibility.post(notification: .layoutChanged, argument: surface)
        } else if let error = controller.errorMessage {
            UIAccessibility.post(notification: .announcement, argument: error)
        }
    }

    private func stateChanged() {
        let state = controller.state
        if state.pendingSettlement == nil { stopAnimator() }
        if state.phase != .settling,
           let card = controller.layout()?.cards.first(where: { $0.item == state.selected }) {
            UIView.performWithoutAnimation { _ = render(card) }
        }
        if lastPhase != state.phase || lastSelected != state.selected
            || lastOlder != state.older || lastNewer != state.newer
            || lastSuspended != controller.interactionSuspended
            || lastCanEditMetadata != controller.canEditCurrentMetadata {
            lastPhase = state.phase
            lastSelected = state.selected
            lastOlder = state.older
            lastNewer = state.newer
            lastSuspended = controller.interactionSuspended
            lastCanEditMetadata = controller.canEditCurrentMetadata
            refreshAccessibility()
        }
    }
}
