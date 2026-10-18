import SwiftUI
import UIKit

/// Divider restoration has a native layout receipt, unlike an ordinary reading
/// request. Apply its pixel command only to that same measured UIScrollView.
@MainActor
final class ConversationNativeScrollViewport {
    private(set) weak var scrollView: UIScrollView?
    private weak var anchor: UIView?
    @MainActor
    private final class Command {
        let id = UUID()
        let target: Double
        let geometry: ScrollGeometry
        let isCurrent: () -> Bool
        let deadline = CACurrentMediaTime() + 2
        var scrollID: ObjectIdentifier?
        var windowID: ObjectIdentifier?

        init(target: Double, geometry: ScrollGeometry, isCurrent: @escaping () -> Bool,
             scrollView: UIScrollView?) {
            self.target = target
            self.geometry = geometry
            self.isCurrent = isCurrent
            scrollID = scrollView.map(ObjectIdentifier.init)
            windowID = scrollView?.window.map(ObjectIdentifier.init)
        }
    }
    private var command: Command?
    private var displayLink: CADisplayLink?
#if DEBUG
    private var requestedTarget: Double?
    private var acceptedCommands = 0
    private var expiredWaits = 0
    var diagnostic: String {
        guard let scrollView else { return "bound=false" }
        return "bound=true,window=\(scrollView.window != nil),bounds=\(scrollView.bounds),content=\(scrollView.contentSize),insets=\(scrollView.adjustedContentInset),target=\(String(describing: requestedTarget)),commands=\(acceptedCommands),expiredWaits=\(expiredWaits)"
    }
#endif

    func bind(_ scrollView: UIScrollView, owner: UIView) {
        if let anchor, anchor !== owner { cancelCommand() }
        if let current = self.scrollView, current !== scrollView { cancelCommand() }
        self.scrollView = scrollView
        anchor = owner
    }

    func unbind(owner: UIView) {
        guard anchor === owner else { return }
        cancelCommand()
        scrollView = nil
        anchor = nil
    }

    func restoreDividerOffset(_ target: Double, geometry: ScrollGeometry,
                              whileCurrent isCurrent: @escaping () -> Bool) {
        if command?.target != target || command?.geometry.viewportHeight != geometry.viewportHeight
            || command?.geometry.contentHeight != geometry.contentHeight || command?.isCurrent() != true {
            command = Command(target: target, geometry: geometry, isCurrent: isCurrent, scrollView: scrollView)
        }
        retryCommand()
        guard command != nil, displayLink == nil else { return }
        let proxy = ConversationScrollCommandTick(viewport: self)
        displayLink = CADisplayLink(target: proxy, selector: #selector(ConversationScrollCommandTick.tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    fileprivate func retryCommand() {
        guard let command else { return }
        guard command.isCurrent() else { cancelCommand(); return }
        let scrollID = scrollView.map(ObjectIdentifier.init)
        let windowID = scrollView?.window.map(ObjectIdentifier.init)
        if let captured = command.scrollID, captured != scrollID { cancelCommand(); return }
        if let captured = command.windowID, captured != windowID { cancelCommand(); return }
        if command.scrollID == nil { command.scrollID = scrollID }
        if command.windowID == nil { command.windowID = windowID }
        if applyDividerOffset(command.target, geometry: command.geometry), self.command?.id == command.id {
            cancelCommand()
        } else if CACurrentMediaTime() >= command.deadline, self.command?.id == command.id {
            // Stop work rather than polling an incompatible viewport forever.
            // The next real geometry/request callback may submit a fresh target.
#if DEBUG
            expiredWaits += 1
#endif
            cancelCommand()
        }
    }

    func cancelDividerRestoration() { cancelCommand() }

    private func cancelCommand() {
        command = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    func applyDividerOffset(_ target: Double, geometry: ScrollGeometry) -> Bool {
#if DEBUG
        requestedTarget = target
#endif
        guard geometry.isUsableForPane, target.isFinite,
              let scrollView, scrollView.window != nil,
              !scrollView.isTracking, !scrollView.isDragging else { return false }
        let inset = scrollView.adjustedContentInset
        let height = scrollView.bounds.height - inset.top - inset.bottom
        guard abs(Double(height) - geometry.viewportHeight) <= 0.5,
              abs(Double(scrollView.contentSize.height) - geometry.contentHeight) <= 0.5,
              target >= 0, target <= max(0, geometry.contentHeight - geometry.viewportHeight) else { return false }
        let nativeMaximum = max(0, Double(scrollView.contentSize.height - height))
        // Independent subpixel size errors can add up at the bottom edge. Never
        // accept an unreachable target that could strand the strict receipt.
        guard target <= nativeMaximum + 0.5 else { return false }
        // Reading coordinates start below the top inset; UIKit's contentOffset
        // starts above it. Keep the native horizontal position untouched.
        let point = CGPoint(x: scrollView.contentOffset.x, y: CGFloat(min(target, nativeMaximum)) - inset.top)
        if abs(scrollView.contentOffset.y - point.y) > 0.5 {
            scrollView.setContentOffset(point, animated: false)
#if DEBUG
            acceptedCommands += 1
#endif
        }
        return true
    }
}

@MainActor
private final class ConversationScrollCommandTick: NSObject {
    private weak var viewport: ConversationNativeScrollViewport?
    init(viewport: ConversationNativeScrollViewport) { self.viewport = viewport }
    @objc func tick(_ link: CADisplayLink) {
        guard let viewport else { link.invalidate(); return }
        viewport.retryCommand()
    }
}

struct ConversationScrollViewportReader: UIViewRepresentable {
    let viewport: ConversationNativeScrollViewport

    func makeUIView(context: Context) -> ConversationScrollViewportAnchor {
        ConversationScrollViewportAnchor(viewport: viewport)
    }
    func updateUIView(_ view: ConversationScrollViewportAnchor, context: Context) { view.resolve() }
    static func dismantleUIView(_ view: ConversationScrollViewportAnchor, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class ConversationScrollViewportAnchor: UIView {
    private let viewport: ConversationNativeScrollViewport

    init(viewport: ConversationNativeScrollViewport) {
        self.viewport = viewport
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
    override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
    override func layoutSubviews() { super.layoutSubviews(); resolve() }

    func resolve() {
        guard window != nil else { detach(); return }
        var node = superview
        while let current = node {
            if let scroll = current as? UIScrollView {
                viewport.bind(scroll, owner: self)
                return
            }
            node = current.superview
        }
        detach()
    }
    func detach() { viewport.unbind(owner: self) }
}
