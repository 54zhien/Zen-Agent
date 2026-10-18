import SwiftUI
import UIKit

/// Divider restoration has a native layout receipt, unlike an ordinary reading
/// request. Apply its pixel command only to that same measured UIScrollView.
@MainActor
final class ConversationNativeScrollViewport {
    private(set) weak var scrollView: UIScrollView?
    private weak var anchor: UIView?
#if DEBUG
    private var requestedTarget: Double?
    private var acceptedCommands = 0
    var diagnostic: String {
        guard let scrollView else { return "bound=false" }
        return "bound=true,window=\(scrollView.window != nil),bounds=\(scrollView.bounds),content=\(scrollView.contentSize),insets=\(scrollView.adjustedContentInset),target=\(String(describing: requestedTarget)),commands=\(acceptedCommands)"
    }
#endif

    func bind(_ scrollView: UIScrollView, owner: UIView) {
        self.scrollView = scrollView
        anchor = owner
    }

    func unbind(owner: UIView) {
        guard anchor === owner else { return }
        scrollView = nil
        anchor = nil
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
        // Reading coordinates start below the top inset; UIKit's contentOffset
        // starts above it. Keep the native horizontal position untouched.
        let point = CGPoint(x: scrollView.contentOffset.x, y: CGFloat(target) - inset.top)
        if abs(scrollView.contentOffset.y - point.y) > 0.5 {
            scrollView.setContentOffset(point, animated: false)
#if DEBUG
            acceptedCommands += 1
#endif
        }
        return true
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
