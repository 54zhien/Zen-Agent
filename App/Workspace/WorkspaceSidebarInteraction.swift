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

    init(hostID: ObjectIdentifier, paneID: ObjectIdentifier, window: UIWindow,
         allowsOpening: Bool, allowsClosing: Bool = true, surfaceView: UIView? = nil) {
        self.hostID = hostID; self.paneID = paneID; self.window = window
        self.allowsOpening = allowsOpening; self.allowsClosing = allowsClosing
        self.surfaceView = surfaceView
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

/// One Window transport for the active host. The anchor itself never receives touches.
@MainActor
final class WorkspaceSidebarInteraction: UIView, UIGestureRecognizerDelegate {
    private let edge = UIScreenEdgePanGestureRecognizer()
    private let reverse = UIPanGestureRecognizer()
    private let closeTap = UITapGestureRecognizer()
    private weak var attachedWindow: UIWindow?
    private var state: WorkspaceNavigationState?
    private var readContext: (() -> WorkspaceSidebarNativeContext?)?
    private var travel: CGFloat = 60
    private var sign: CGFloat = 1
    private typealias Owner = (host: ObjectIdentifier, pane: ObjectIdentifier, window: ObjectIdentifier)
    private var captured: Owner?
    private var capturedGestureID: UUID?
    private var tapOwner: Owner?

    override init(frame: CGRect) {
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
            // Do not reset a recognizer's edge configuration during its own Pan.
            for recognizer in [edge, reverse, closeTap] { attachedWindow?.removeGestureRecognizer(recognizer) }
            attachedWindow = nil
            captured = nil
            edge.edges = edges
        }
        if window !== attachedWindow { attach() }
        if captured != nil, !sameOwner(captured) {
            if state.gestureID == capturedGestureID { state.reset() }
            captured = nil; capturedGestureID = nil
        }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    private func attach() {
        guard window !== attachedWindow else { return }
        detach()
        guard let window else { return }
        attachedWindow = window
        for recognizer in [edge, reverse, closeTap] { window.addGestureRecognizer(recognizer) }
    }
    func detach() {
        for recognizer in [edge, reverse, closeTap] { attachedWindow?.removeGestureRecognizer(recognizer) }
        attachedWindow = nil
        captured = nil
        capturedGestureID = nil
        tapOwner = nil
        state?.reset()
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
        guard let window = attachedWindow, let current = readContext?(), current.window === window,
              convert(bounds, to: window).contains(touch.location(in: window)) else {
            record("recv \(kind(gestureRecognizer)) rejected context=\(readContext?() != nil),anchor=\(bounds),window=\(window === attachedWindow)")
            return false
        }
        record("recv \(kind(gestureRecognizer)) opening=\(current.allowsOpening),closing=\(current.allowsClosing),point=\(touch.location(in: window)),anchor=\(convert(bounds, to: window))")
        if gestureRecognizer === edge { return state?.isOpen == false && current.allowsOpening }
        guard state?.isOpen == true, current.allowsClosing,
              let surface = current.surfaceView, let hit = touch.view,
              hit === surface || hit.isDescendant(of: surface) else {
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
        if gestureRecognizer === closeTap { return state.isOpen && current.allowsClosing && sameOwner(tapOwner) }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: current.window)
        record("velocity \(kind(gestureRecognizer)) \(velocity),opening=\(current.allowsOpening),closing=\(current.allowsClosing)")
        guard velocity.x.isFinite, velocity.y.isFinite, abs(velocity.x) > abs(velocity.y) * 1.1 else { return false }
        return gestureRecognizer === edge ? (!state.isOpen && current.allowsOpening && velocity.x * sign > 0)
            : (state.isOpen && current.allowsClosing && velocity.x * sign < 0)
    }

    @objc private func changed(_ recognizer: UIGestureRecognizer) {
        guard let state else { return }
        record("callback \(kind(recognizer)) state=\(recognizer.state.rawValue)")
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
        switch pan.state {
        case .began:
            guard state.begin(eligible: allowed) else { return }
            captured = (current.hostID, current.paneID, ObjectIdentifier(current.window))
            capturedGestureID = state.gestureID
            state.drag(displacement: Double(pan.translation(in: current.window).x * sign), travel: Double(travel))
        case .changed, .ended:
            guard let capturedGestureID, state.gestureID == capturedGestureID else {
                captured = nil; self.capturedGestureID = nil; return
            }
            guard sameOwner(captured), allowed else {
                state.reset(); captured = nil; self.capturedGestureID = nil; return
            }
            // Release can contain the last displacement even without a changed callback.
            state.drag(displacement: Double(pan.translation(in: current.window).x * sign), travel: Double(travel))
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
