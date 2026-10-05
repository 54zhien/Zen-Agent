import SwiftUI
import UIKit

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

    override convenience init(frame: CGRect) {
        self.init(frame: frame, edge: UIScreenEdgePanGestureRecognizer())
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edge { edgeTouchOwner = nil; edgeTouchOrigin = nil }
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
              !state.isDragging, state.settlementID == nil else { return false }
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
            guard sameOwner(edgeTouchOwner) else { return false }
            // A coalesced native edge pan can begin with zero velocity and
            // translation. Its admitted initial touch still records direction.
            if velocity == .zero { direction = edgeDisplacement(pan, in: current.window) }
        }
        record("direction \(kind(gestureRecognizer)) \(direction)")
        guard direction.x.isFinite, direction.y.isFinite, abs(direction.x) > abs(direction.y) * 1.1 else { return false }
        return gestureRecognizer === edge ? (!state.isOpen && current.allowsOpening && direction.x * sign > 0)
            : (state.isOpen && current.allowsClosing && direction.x * sign < 0)
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
        let allowed = recognizer === edge ? current.allowsOpening : current.allowsClosing
        // Measure opening in the stable Window space, including motion before
        // recognition. Keep the touch origin through the final release sample.
        let displacement = recognizer === edge ? edgeDisplacement(pan, in: current.window).x
            : pan.translation(in: current.window).x
        switch pan.state {
        case .began:
            if recognizer === edge, !sameOwner(edgeTouchOwner) { return }
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
}
