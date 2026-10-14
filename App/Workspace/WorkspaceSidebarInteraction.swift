import SwiftUI
import UIKit
#if DEBUG
import UIKit.UIGestureRecognizerSubclass
#endif

#if DEBUG
/// Observe UIKit's real transition/prevention seam without replacing its decision.
/// Only the existing native UI fixture uses this transport; no touch is retained.
@MainActor
private final class WorkspaceSidebarEdgeDiagnostic: UIScreenEdgePanGestureRecognizer {
    private var attempt = 0
    private var beganAt: TimeInterval = 0
    private var phases: [String: Int] = [:]
    private var phaseSamples: [String: String] = [:]
    private var decisions: [String] = []
    private var resets: [String] = []

    var snapshot: String {
        "attempt=\(attempt);beganAt=\(beganAt);phases=\(phases);samples=\(phaseSamples);reset=[\(resets.joined(separator: " | "))];decisions=[\(decisions.joined(separator: " | "))]"
    }

    private var motion: String {
        let window = view?.window
        return "state=\(state.rawValue),translation=\(translation(in: window)),velocity=\(velocity(in: window)),location=\(location(in: window))"
    }

    private func observe(_ phase: String, before: String) {
        phases[phase, default: 0] += 1
        let sample = "before{\(before)},after{\(motion)}"
        if phaseSamples[phase + "First"] == nil { phaseSamples[phase + "First"] = sample }
        phaseSamples[phase + "Last"] = sample
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        attempt += 1; beganAt = ProcessInfo.processInfo.systemUptime
        phases.removeAll(); phaseSamples.removeAll()
        let before = motion
        super.touchesBegan(touches, with: event)
        observe("began", before: before)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = motion
        super.touchesMoved(touches, with: event)
        observe("moved", before: before)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = motion
        super.touchesEnded(touches, with: event)
        observe("ended", before: before)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = motion
        super.touchesCancelled(touches, with: event)
        observe("cancelled", before: before)
    }
    override func reset() {
        resets.append("attempt=\(attempt),at=\(ProcessInfo.processInfo.systemUptime)," + motion)
        if resets.count > 4 { resets.removeFirst() }
        super.reset()
    }

    private func decision(_ method: String, peer: UIGestureRecognizer, result: Bool) -> Bool {
        let peerView = peer.view.map { "\(type(of: $0)):\(ObjectIdentifier($0))" } ?? "nil"
        decisions.append("attempt=\(attempt),at=\(ProcessInfo.processInfo.systemUptime),\(method)=\(result),own=\(state.rawValue),peer=\(ObjectIdentifier(peer)):\(type(of: peer)),peerState=\(peer.state.rawValue),view=\(peerView)")
        if decisions.count > 48 { decisions.removeFirst() }
        return result
    }
    override func canPrevent(_ peer: UIGestureRecognizer) -> Bool {
        decision("canPrevent", peer: peer, result: super.canPrevent(peer))
    }
    override func canBePrevented(by peer: UIGestureRecognizer) -> Bool {
        decision("canBePrevented", peer: peer, result: super.canBePrevented(by: peer))
    }
    override func shouldRequireFailure(of peer: UIGestureRecognizer) -> Bool {
        decision("requiresFailure", peer: peer, result: super.shouldRequireFailure(of: peer))
    }
    override func shouldBeRequiredToFail(by peer: UIGestureRecognizer) -> Bool {
        decision("requiredToFail", peer: peer, result: super.shouldBeRequiredToFail(by: peer))
    }
}
#endif

@MainActor
struct WorkspaceSidebarNativeContext {
    let hostID: ObjectIdentifier
    let paneID: ObjectIdentifier
    let window: UIWindow
    let allowsOpening: Bool
    let allowsClosing: Bool
    weak var surfaceView: UIView?
    let additionalClosingViews: [UIView]

    init(hostID: ObjectIdentifier, paneID: ObjectIdentifier, window: UIWindow,
         allowsOpening: Bool, allowsClosing: Bool = true, surfaceView: UIView? = nil,
         additionalClosingViews: [UIView] = []) {
        self.hostID = hostID; self.paneID = paneID; self.window = window
        self.allowsOpening = allowsOpening; self.allowsClosing = allowsClosing
        self.surfaceView = surfaceView
        self.additionalClosingViews = additionalClosingViews
    }

    func containsClosingView(_ view: UIView) -> Bool {
        let roots = additionalClosingViews + [surfaceView].compactMap { $0 }
        return view.window === window && roots.contains { view === $0 || view.isDescendant(of: $0) }
    }
}

@MainActor
struct WorkspaceSidebarGestureBridge: UIViewRepresentable {
    let state: WorkspaceNavigationState
    let travel: CGFloat
    let isRightToLeft: Bool
    let context: () -> WorkspaceSidebarNativeContext?

    func makeUIView(context: Context) -> WorkspaceSidebarInteraction {
        let view = WorkspaceSidebarInteraction()
        view.isUserInteractionEnabled = false
        configure(view)
        return view
    }
    func updateUIView(_ view: WorkspaceSidebarInteraction, context: Context) { configure(view) }
    private func configure(_ view: WorkspaceSidebarInteraction) {
        view.configure(state: state, travel: travel, isRightToLeft: isRightToLeft, context: context)
    }
    static func dismantleUIView(_ view: WorkspaceSidebarInteraction, coordinator: Void) { view.detach() }
}

/// One scene transport for the active host. The anchor itself never receives touches.
@MainActor
final class WorkspaceSidebarInteraction: UIView, UIGestureRecognizerDelegate {
    private let edge: UIScreenEdgePanGestureRecognizer
    private let reverse = UIPanGestureRecognizer()
    private let closeTap = UITapGestureRecognizer()
    private weak var attachedWindow: UIWindow?
    private weak var attachedEdgeView: UIView?
    private struct WindowGeometry: Equatable {
        let bounds: CGRect
        let edgeBounds: CGRect
        let orientation: UIInterfaceOrientation
        init(_ window: UIWindow, edgeView: UIView) {
            bounds = window.bounds
            edgeBounds = edgeView.bounds
            orientation = window.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
        }
    }
    private var attachedGeometry: WindowGeometry?
    private var state: WorkspaceNavigationState?
    private var readContext: (() -> WorkspaceSidebarNativeContext?)?
    private var travel: CGFloat = 60
    private var sign: CGFloat = 1
    private typealias Owner = (host: ObjectIdentifier, pane: ObjectIdentifier, window: ObjectIdentifier)
    private var captured: Owner?
    private var capturedGestureID: UUID?
    private var tapOwner: Owner?
    private var edgeTouchOwner: Owner?
    private var edgeTouchOrigin: CGPoint?
    private var edgeRejected = false

    override convenience init(frame: CGRect) {
#if DEBUG
        let edge: UIScreenEdgePanGestureRecognizer = ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1"
            && UIDevice.current.userInterfaceIdiom == .pad
            ? WorkspaceSidebarEdgeDiagnostic() : UIScreenEdgePanGestureRecognizer()
#else
        let edge = UIScreenEdgePanGestureRecognizer()
#endif
        self.init(frame: frame, edge: edge)
    }

    init(frame: CGRect, edge: UIScreenEdgePanGestureRecognizer) {
        self.edge = edge
        super.init(frame: frame)
        for recognizer in [edge, reverse, closeTap] {
            recognizer.delegate = self
            // The shifted Surface tap must not also become a Timeline blank tap
            // that dismisses the retained editor. Rail controls are excluded below.
            recognizer.cancelsTouchesInView = true
            recognizer.addTarget(self, action: #selector(changed(_:)))
        }
        edge.maximumNumberOfTouches = 1
        reverse.maximumNumberOfTouches = 1
        closeTap.require(toFail: reverse)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: WorkspaceNavigationState, travel: CGFloat, isRightToLeft: Bool,
                   context: @escaping () -> WorkspaceSidebarNativeContext?) {
        self.state = state
        self.readContext = context
#if DEBUG
        state.nativeGestureSnapshot = { [weak self] in self?.gestureSnapshot() ?? "detached" }
#endif
        self.travel = max(1, travel)
        self.sign = isRightToLeft ? -1 : 1
        let edges: UIRectEdge = isRightToLeft ? .right : .left
        if edge.edges != edges {
            // Cancel the old direction before changing the native edge policy.
            detach()
            edge.edges = edges
        }
        attach()
        if edgeTouchOwner != nil, !sameOwner(edgeTouchOwner) {
            record("configure cleared edge owner captured=\(String(describing: edgeTouchOwner)),currentHost=\(String(describing: readContext?()?.hostID)),currentPane=\(String(describing: readContext?()?.paneID))")
            edgeTouchOwner = nil; edgeTouchOrigin = nil
        }
        if captured != nil, !sameOwner(captured) {
            if state.gestureID == capturedGestureID { state.reset() }
            captured = nil; capturedGestureID = nil
        }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    override func layoutSubviews() { super.layoutSubviews(); attach() }
    private func attach() {
        let edgeView: UIView? = window.map { window in
            if let root = window.rootViewController?.viewIfLoaded,
               root.window === window, isDescendant(of: root) { return root }
            return window
        }
        let geometry = window.flatMap { window in edgeView.map { WindowGeometry(window, edgeView: $0) } }
        guard window !== attachedWindow || edgeView !== attachedEdgeView || geometry != attachedGeometry else { return }
        detach()
        guard let window, let edgeView else { return }
        attachedWindow = window
        attachedEdgeView = edgeView
        attachedGeometry = geometry
        edgeView.addGestureRecognizer(edge)
        for recognizer in [reverse, closeTap] { window.addGestureRecognizer(recognizer) }
        // The scene's root content provides the interface coordinate space for
        // screen-edge recognition; Window identity still owns admission and Pan
        // measurements. Closing keeps its independently verified Window transport.
        record("attach bounds=\(window.bounds),edgeView=\(type(of: edgeView)),edgeBounds=\(edgeView.bounds),orientation=\(geometry?.orientation.rawValue ?? 0),edge=\(edge.edges.rawValue)")
    }
    func detach() {
        if edgeTouchOwner != nil || edge.state != .possible {
            record("detach edge state=\(edge.state.rawValue),captured=\(String(describing: edgeTouchOwner)),origin=\(String(describing: edgeTouchOrigin))")
        }
        attachedEdgeView?.removeGestureRecognizer(edge)
        for recognizer in [reverse, closeTap] { attachedWindow?.removeGestureRecognizer(recognizer) }
        attachedWindow = nil
        attachedEdgeView = nil
        attachedGeometry = nil
        captured = nil
        capturedGestureID = nil
        tapOwner = nil
        edgeTouchOwner = nil
        edgeTouchOrigin = nil
        edgeRejected = false
        if let state, state.blocksLift || state.isOpen { state.reset() }
    }

    private func sameOwner(_ captured: Owner?) -> Bool {
        guard let captured, let current = readContext?(), current.window === attachedWindow else { return false }
        return captured.host == current.hostID && captured.pane == current.paneID
            && captured.window == ObjectIdentifier(current.window)
    }

    private func record(_ message: @autoclosure () -> String) {
#if DEBUG
        state?.recordNative(message())
#endif
    }

    private func kind(_ gesture: UIGestureRecognizer) -> String {
        gesture === edge ? "edge" : gesture === reverse ? "reverse" : "tap"
    }

#if DEBUG
    private func gestureSnapshot() -> String {
        guard let window = attachedWindow else { return "no-window" }
        let current = readContext?()
        var scroll: UIScrollView?
        var hit = edgeTouchOrigin.flatMap { window.hitTest($0, with: nil) }
        while let view = hit {
            if let candidate = view as? UIScrollView { scroll = candidate; break }
            hit = view.superview
        }
        return "edgeState=\(edge.state.rawValue),translation=\(edge.translation(in: window)),velocity=\(edge.velocity(in: window)),location=\(edge.location(in: window)),origin=\(String(describing: edgeTouchOrigin)),captured=\(String(describing: edgeTouchOwner)),currentHost=\(String(describing: current?.hostID)),currentPane=\(String(describing: current?.paneID)),window=\(ObjectIdentifier(window)),scrollPan=\(scroll.map { "state=\($0.panGestureRecognizer.state.rawValue),translation=\($0.panGestureRecognizer.translation(in: window))" } ?? "none"),edgeNativeTrace=[\((edge as? WorkspaceSidebarEdgeDiagnostic)?.snapshot ?? "disabled")]"
    }
#endif

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edge { edgeTouchOwner = nil; edgeTouchOrigin = nil; edgeRejected = false }
        guard let window = attachedWindow, let current = readContext?(), current.window === window,
              convert(bounds, to: window).contains(touch.location(in: window)) else {
            record("recv \(kind(gestureRecognizer)) rejected context=\(readContext?() != nil),anchor=\(bounds),window=\(window === attachedWindow)")
            return false
        }
        record("recv \(kind(gestureRecognizer)) opening=\(current.allowsOpening),closing=\(current.allowsClosing),point=\(touch.location(in: window)),anchor=\(convert(bounds, to: window))")
        if gestureRecognizer === edge {
            let eligible = state?.isOpen == false && current.allowsOpening
            let x = touch.location(in: window).x
            let distance = sign > 0 ? x - window.bounds.minX : window.bounds.maxX - x
            // Limit failure priority to this touch's leading Rail strip. The
            // system screen-edge recognizer still decides its actual edge radius.
            if eligible, distance >= 0, distance <= travel {
                edgeTouchOwner = (current.hostID, current.paneID, ObjectIdentifier(window))
                edgeTouchOrigin = touch.location(in: window)
            }
            return eligible
        }
        guard state?.isOpen == true, current.allowsClosing,
              let hit = touch.view, current.containsClosingView(hit) else {
            record("recv close rejected surface ancestry hit=\(touch.view.map { String(describing: type(of: $0)) } ?? "nil")")
            return false
        }
        if gestureRecognizer === reverse {
            var node: UIView? = hit
            while let view = node {
                if let editor = view as? UITextView, editor.selectedTextRange?.isEmpty == false { return false }
                node = view.superview
            }
        }
        let x = touch.location(in: window).x
        let distance = sign > 0 ? x - window.bounds.minX : window.bounds.maxX - x
        guard distance >= travel else { return false }
        if gestureRecognizer === closeTap {
            tapOwner = (current.hostID, current.paneID, ObjectIdentifier(window))
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        record("shouldBegin \(kind(gestureRecognizer)) raw=\(gestureRecognizer.state.rawValue)")
        guard let state, let current = readContext?(), current.window === attachedWindow,
              !state.isDragging, state.settlementID == nil else {
            record("begin \(kind(gestureRecognizer)) rejected context/window/drag/settlement")
            return false
        }
        if gestureRecognizer === closeTap {
            let admitted = state.isOpen && current.allowsClosing && sameOwner(tapOwner)
            record("tap begin admitted=\(admitted),sameOwner=\(sameOwner(tapOwner))")
            return admitted
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: current.window)
        record("velocity \(kind(gestureRecognizer)) \(velocity),opening=\(current.allowsOpening),closing=\(current.allowsClosing)")
        var direction = velocity
        if gestureRecognizer === edge {
            let ownerMatches = sameOwner(edgeTouchOwner)
            record("begin edge open=\(state.isOpen),allows=\(current.allowsOpening),ownerMatches=\(ownerMatches),captured=\(String(describing: edgeTouchOwner)),currentHost=\(current.hostID),currentPane=\(current.paneID),window=\(ObjectIdentifier(current.window))")
            guard !state.isOpen, current.allowsOpening, ownerMatches else {
                record("begin edge rejected admission")
                return false
            }
            // A coalesced native edge pan can begin with zero velocity and
            // translation. Its admitted initial touch still records direction.
            if velocity == .zero { direction = edgeDisplacement(pan, in: current.window) }
            // UIKit may ask before updating either motion sample. Admit the
            // owned native edge provisionally; changedEdge waits for actual
            // horizontal opening motion before starting navigation state.
            if direction == .zero {
                record("begin edge admitted provisionally")
                return true
            }
        }
        record("direction \(kind(gestureRecognizer)) \(direction)")
        guard direction.x.isFinite, direction.y.isFinite, abs(direction.x) > abs(direction.y) * 1.1 else {
            record("begin \(kind(gestureRecognizer)) rejected nonhorizontal/nonfinite motion")
            return false
        }
        let admitted = gestureRecognizer === edge ? (!state.isOpen && current.allowsOpening && direction.x * sign > 0)
            : (state.isOpen && current.allowsClosing && direction.x * sign < 0)
        record("begin \(kind(gestureRecognizer)) admitted=\(admitted)")
        return admitted
    }

    private func edgeDisplacement(_ pan: UIPanGestureRecognizer, in window: UIWindow) -> CGPoint {
        guard let origin = edgeTouchOrigin else { return .zero }
        let point = pan.location(in: window)
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard otherGestureRecognizer !== edge, otherGestureRecognizer !== reverse,
              otherGestureRecognizer !== closeTap,
              !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer),
              let state, !state.isDragging, state.settlementID == nil,
              let current = readContext?(), current.window === attachedWindow,
              let otherView = otherGestureRecognizer.view, otherView.window === current.window else { return false }
        let admitted: Bool
        if gestureRecognizer === edge {
            // UIKit's dynamic failure requirement gives the admitted edge gesture
            // priority over content recognizers, including landscape safe-area hosts.
            admitted = !state.isOpen && current.allowsOpening
                && sameOwner(edgeTouchOwner)
                && otherView.isDescendant(of: current.window)
        } else if gestureRecognizer === closeTap {
            // A shifted Surface tap restores navigation before its Timeline or
            // editor can interpret the same touch. Rail controls stay outside it.
            admitted = state.isOpen && current.allowsClosing
                && current.containsClosingView(otherView)
        } else { admitted = false }
        record("priority \(kind(gestureRecognizer)) over \(String(describing: type(of: otherGestureRecognizer)))=\(admitted),edgeOrigin=\(String(describing: edgeTouchOrigin)),edgeOwner=\(sameOwner(edgeTouchOwner))")
        return admitted
    }

    @objc private func changed(_ recognizer: UIGestureRecognizer) {
        guard let state else { return }
        record("callback \(kind(recognizer)) state=\(recognizer.state.rawValue)")
        defer {
            if recognizer === edge,
               recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                edgeTouchOwner = nil
                edgeTouchOrigin = nil
                edgeRejected = false
            }
        }
        if recognizer === closeTap {
            if recognizer.state == .ended, sameOwner(tapOwner), readContext?()?.allowsClosing == true {
                state.closeSidebar()
            }
            tapOwner = nil
            return
        }
        guard let pan = recognizer as? UIPanGestureRecognizer, let current = readContext?(),
              current.window === attachedWindow else {
            if state.gestureID == capturedGestureID, capturedGestureID != nil { state.reset() }
            captured = nil; capturedGestureID = nil
            return
        }
        if recognizer === edge {
            changedEdge(pan, context: current, state: state)
            return
        }
        let allowed = current.allowsClosing
        let displacement = pan.translation(in: current.window).x
        switch pan.state {
        case .began:
            guard state.begin(eligible: allowed) else { return }
            captured = (current.hostID, current.paneID, ObjectIdentifier(current.window))
            capturedGestureID = state.gestureID
            state.drag(displacement: Double(displacement * sign), travel: Double(travel))
        case .changed, .ended:
            guard let capturedGestureID, state.gestureID == capturedGestureID else {
                captured = nil; self.capturedGestureID = nil; return
            }
            guard sameOwner(captured), allowed else {
                state.reset(); captured = nil; self.capturedGestureID = nil; return
            }
            // Release can contain the last displacement even without a changed callback.
            state.drag(displacement: Double(displacement * sign), travel: Double(travel))
            if pan.state == .ended {
                state.end(velocity: Double(pan.velocity(in: current.window).x * sign), travel: Double(travel), cancelled: false)
                captured = nil
                self.capturedGestureID = nil
            }
        case .cancelled, .failed:
            if state.gestureID == capturedGestureID, capturedGestureID != nil {
                state.end(velocity: 0, travel: Double(travel), cancelled: true)
            }
            captured = nil
            capturedGestureID = nil
        default: break
        }
    }

    private func changedEdge(_ pan: UIPanGestureRecognizer, context: WorkspaceSidebarNativeContext,
                             state: WorkspaceNavigationState) {
        switch pan.state {
        case .began, .changed, .ended:
            guard !edgeRejected else { return }
            guard sameOwner(edgeTouchOwner), context.allowsOpening, !state.isOpen else {
                rejectEdge(state); return
            }
            // Window coordinates preserve motion before recognition and while
            // the content moves. A zero initial sample does not move the Rail.
            let delta = edgeDisplacement(pan, in: context.window)
            guard delta.x.isFinite, delta.y.isFinite else { rejectEdge(state); return }
            if capturedGestureID == nil {
                guard delta != .zero else { return }
                guard abs(delta.x) > abs(delta.y) * 1.1, delta.x * sign > 0,
                      state.begin(eligible: true) else { rejectEdge(state); return }
                captured = (context.hostID, context.paneID, ObjectIdentifier(context.window))
                capturedGestureID = state.gestureID
            }
            guard state.gestureID == capturedGestureID, sameOwner(captured) else {
                rejectEdge(state); return
            }
            state.drag(displacement: Double(delta.x * sign), travel: Double(travel))
            if pan.state == .ended {
                state.end(velocity: Double(pan.velocity(in: context.window).x * sign),
                          travel: Double(travel), cancelled: false)
                captured = nil; capturedGestureID = nil
            }
        case .cancelled, .failed:
            if state.gestureID == capturedGestureID, capturedGestureID != nil {
                state.end(velocity: 0, travel: Double(travel), cancelled: true)
            }
            captured = nil; capturedGestureID = nil
        default: break
        }
    }

    private func rejectEdge(_ state: WorkspaceNavigationState) {
        edgeRejected = true
        if state.gestureID == capturedGestureID, capturedGestureID != nil { state.reset() }
        captured = nil; capturedGestureID = nil
    }
}
