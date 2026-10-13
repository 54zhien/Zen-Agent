import UIKit
import Testing
@testable import ZenAgent

@Suite("Blur capture failure admission", .serialized)
@MainActor
struct TopEdgeCaptureFailureTests {
    @Test("incomplete native capture cannot repeatedly retry without a new invalidation")
    func incompleteCaptureConsumesOneInvalidation() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        root.view.layoutIfNeeded()
        let source = RefusingCaptureView(frame: root.view.bounds)
        root.view.addSubview(source)
        let edge = ConversationTopEdgeMaterial(frame: CGRect(x: 0, y: 0, width: source.bounds.width, height: 110))
        root.view.addSubview(edge)
        edge.configure(source: source, safeTop: 62)
        edge.layoutIfNeeded()
        edge.refreshIfNeeded()
        #expect(source.attempts == 1)
        for _ in 0..<5 { edge.refreshIfNeeded() }
        #expect(source.attempts == 1 && edge.captureCount == 0)
        edge.invalidate()
        edge.refreshIfNeeded()
        #expect(source.attempts == 2)
    }


}

@MainActor
private final class RefusingCaptureView: UIView {
    private(set) var attempts = 0
    override func drawHierarchy(in rect: CGRect, afterScreenUpdates afterUpdates: Bool) -> Bool {
        attempts += 1
        return false
    }
}
