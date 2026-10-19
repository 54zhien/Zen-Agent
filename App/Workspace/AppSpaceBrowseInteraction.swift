import SwiftUI
import UIKit

/// Native input and animation transport. The controller owns only projections;
/// the existing Surface keeps its hosting child and untransformed bounds.
@MainActor
final class AppSpaceBrowseInteraction: NSObject, UIGestureRecognizerDelegate {
    enum Direction: Equatable { case older, newer }
    let controller: AppSpaceBrowseController
    let recognizer = UIPanGestureRecognizer()
    private let transportOwner = UUID()
    var isCurrentOwner: Bool { controller.ownsTransport(transportOwner) }
    private weak var surface: SurfaceClipView?
    private weak var coordinates: UIView?
    private let canBrowse: () -> Bool
    private let render: (AppSpaceBrowseGeometry.Card) -> Bool
    private let refreshAccessibility: () -> Void
    private var displayLink: CADisplayLink?
    private lazy var clockTarget = AppSpaceBrowseClockTarget(owner: self)
    private var motion: AppSpaceBrowseMotion?
    private var lastTimestamp: TimeInterval?
    private var dragOffset = 0.0
    private var lastTranslation = 0.0
    private var preservesPresentation = false
    var isAnimating: Bool { motion != nil }
    private let windowCornerGeometry = WindowCornerGeometry()
#if DEBUG
    private var diagnosticEvents: [String] = []
    var diagnostic: String {
        "owner=\(isCurrentOwner),enabled=\(recognizer.isEnabled),native=\(recognizer.state.rawValue),phase=\(controller.state.phase),canBrowse=\(canBrowse());events="
            + diagnosticEvents.joined(separator: " | ")
    }
    private func record(_ event: String) {
        diagnosticEvents.append(event)
        if diagnosticEvents.count > 24 { diagnosticEvents.removeFirst() }
    }
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
        controller.claimTransport(transportOwner) { [weak self] in self?.stateChanged() }
        updateViewport()
    }

    func updateViewport() {
        guard isCurrentOwner, let coordinates else { return }
#if DEBUG
        if controller.viewportSize != coordinates.bounds.size || controller.safeArea != coordinates.safeAreaInsets {
            record("viewport=\(coordinates.bounds.size) insets=\(coordinates.safeAreaInsets) phase=\(controller.state.phase)")
        }
#endif
        controller.updateViewport(size: coordinates.bounds.size, safeArea: coordinates.safeAreaInsets,
            displayCornerRadius: coordinates.window.map { windowCornerGeometry.radius(in: $0) } ?? 0)
    }

    func updateAvailability() {
        // UIKit can still report the dismissing alert here. Keep the recognizer
        // available after logical dismissal; the delegate checks actual overlays
        // again at gesture start, so a transition cannot leave it disabled forever.
        let enabled = isCurrentOwner && controller.isPresented && !controller.interactionSuspended
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    var canNavigate: Bool { isCurrentOwner && canBrowse() && controller.state.phase == .idle }
    var hasNavigationActions: Bool {
        isCurrentOwner && controller.isPresented && !controller.interactionSuspended && controller.state.phase == .idle
    }

#if DEBUG
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        record("touch=\(touch.location(in: coordinates?.window ?? coordinates)) hit=\(touch.view.map { String(describing: type(of: $0)) } ?? "nil")")
        return true
    }
#endif

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isCurrentOwner, gestureRecognizer === recognizer, canBrowse(),
              controller.state.phase == .idle || isAnimating,
              controller.layout() != nil, let coordinates else {
#if DEBUG
            record("begin denied owner=\(isCurrentOwner) canBrowse=\(canBrowse()) phase=\(controller.state.phase)")
#endif
            return false
        }
        let velocity = recognizer.velocity(in: coordinates.window ?? coordinates)
#if DEBUG
        record("begin velocity=\(velocity)")
#endif
        return velocity.x.isFinite && velocity.y.isFinite && abs(velocity.x) > abs(velocity.y) * 1.1
    }

    @objc private func gestureChanged(_ pan: UIPanGestureRecognizer) {
        guard isCurrentOwner, let coordinates, let layout = controller.layout() else { cancel(); return }
        let reference = coordinates.window ?? coordinates
#if DEBUG
        record("pan=\(pan.state.rawValue) x=\(pan.translation(in: reference).x) vx=\(pan.velocity(in: reference).x) phase=\(controller.state.phase)")
#endif
        switch pan.state {
        case .began:
            let catchesMotion = isAnimating
            let caughtOffset = motion?.offset ?? controller.state.offset
            stopMotion()
            guard canBrowse(), catchesMotion || controller.begin() else { return }
            dragOffset = caughtOffset
            lastTranslation = 0
            drag(pan, reference: reference, travel: Double(layout.travel))
        case .changed:
            drag(pan, reference: reference, travel: Double(layout.travel))
        case .ended:
            // UIKit may deliver the final displacement only with release. Its
            // velocity can already be zero, so the last changed sample is stale.
            drag(pan, reference: reference, travel: Double(layout.travel))
            guard controller.state.phase == .dragging else { return }
            let velocity = Double(pan.velocity(in: reference).x) / Double(layout.travel)
            guard velocity.isFinite else { cancel(); return }
            start(AppSpaceBrowseMotion(offset: min(1, max(-1, dragOffset)), velocity: velocity))
        case .cancelled, .failed: cancel()
        default: break
        }
    }

    @discardableResult
    func navigate(_ direction: Direction) -> Bool {
        guard isCurrentOwner, canBrowse(), controller.state.phase == .idle,
              (direction == .older ? controller.state.older : controller.state.newer) != nil,
              controller.layout() != nil, controller.begin() else { return false }
        var motion = AppSpaceBrowseMotion(offset: 0, velocity: 0)
        motion.snap(to: direction == .older ? 1 : -1)
        start(motion)
        return true
    }

    private func drag(_ pan: UIPanGestureRecognizer, reference: UIView, travel: Double) {
        let translation = Double(pan.translation(in: reference).x)
        dragOffset += (translation - lastTranslation) / travel
        lastTranslation = translation
        guard let remaining = withAnimation(nil, { controller.move(to: dragOffset) }) else {
            cancel()
            announce(committed: false)
            return
        }
        dragOffset = remaining
    }

    private func start(_ value: AppSpaceBrowseMotion) {
        stopMotion()
        var motion = value
        if let target = motion.target,
           (target > 0 && controller.state.older == nil) || (target < 0 && controller.state.newer == nil) {
            motion.snap(to: 0)
        }
        self.motion = motion
        if UIAccessibility.isReduceMotionEnabled {
            guard withAnimation(nil, { controller.move(to: motion.destinationWithoutAnimation) }) != nil else {
                cancel()
                announce(committed: false)
                return
            }
            finishMotion()
            return
        }
        let link = CADisplayLink(target: clockTarget, selector: #selector(AppSpaceBrowseClockTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func displayFrame(_ link: CADisplayLink) {
        guard link === displayLink else { return }
        let delta = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        advance(deltaTime: delta)
    }

    func advance(deltaTime: TimeInterval) {
        guard isCurrentOwner, canBrowse(), controller.state.phase == .dragging,
              var motion else { stopMotion(); return }
        motion.advance(deltaTime: deltaTime)
        guard let remaining = withAnimation(nil, { controller.move(to: motion.offset) }) else {
            cancel()
            announce(committed: false)
            return
        }
        motion.rebase(by: motion.offset - remaining)
        if abs(controller.state.offset - remaining) > 0.000001, motion.target != 0 {
            motion.returnFromBoundary(offset: min(1, max(-1, remaining)))
        }
        self.motion = motion
        if motion.isFinished { finishMotion() }
    }

    private func finishMotion() {
        stopMotion()
        guard let settlement = controller.end(velocity: 0, travel: 1) else { cancel(); return }
        let committed = withAnimation(nil) { controller.complete(settlement, finished: true) }
        announce(committed: committed)
    }

    func cancel(preservingPresentation: Bool = false) {
#if DEBUG
        record("cancel owner=\(isCurrentOwner) phase=\(controller.state.phase)")
#endif
        stopMotion()
        guard isCurrentOwner else { return }
        preservesPresentation = preservingPresentation
        withAnimation(nil) { controller.cancel() }
        preservesPresentation = false
    }

    func unbind() {
        cancel()
        controller.releaseTransport(transportOwner)
        surface?.removeGestureRecognizer(recognizer)
    }

    private func stopMotion() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        motion = nil
    }

    private func announce(committed: Bool) {
        if committed {
            UIAccessibility.post(notification: .layoutChanged, argument: surface)
        } else if let error = controller.errorMessage {
            UIAccessibility.post(notification: .announcement, argument: error)
        }
    }

    private func stateChanged() {
        guard isCurrentOwner else { return }
        let state = controller.state
        if state.phase == .idle { stopMotion() }
        if !preservesPresentation, state.phase != .settling,
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

@MainActor
private final class AppSpaceBrowseClockTarget: NSObject {
    weak var owner: AppSpaceBrowseInteraction?
    init(owner: AppSpaceBrowseInteraction) { self.owner = owner; super.init() }
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.displayFrame(link)
    }
}
