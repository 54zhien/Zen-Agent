import UIKit
import Testing
import SwiftUI
@testable import ZenAgent

@MainActor
private final class BlurStripeView: UIView {
    override func draw(_ rect: CGRect) {
        UIColor.systemBackground.setFill()
        UIRectFill(bounds)
        for x in stride(from: CGFloat(0), to: 220, by: 4) {
            UIColor.black.setFill()
            UIRectFill(CGRect(x: x, y: 0, width: 2, height: bounds.height))
            UIColor.white.setFill()
            UIRectFill(CGRect(x: x + 2, y: 0, width: 2, height: bounds.height))
        }
    }
}

@Suite("Actual progressive content blur", .serialized)
@MainActor
struct ConversationTopEdgeBlurTests {
    @Test("Sidebar transport reuses its strip despite content invalidations and refreshes after release")
    func sidebarTransportDoesNotCaptureOnTheMainThread() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        root.view.layoutIfNeeded()
        let source = BlurStripeView(frame: root.view.bounds)
        root.view.addSubview(source)
        _ = UIGraphicsImageRenderer(size: source.bounds.size).image { _ in
            _ = source.drawHierarchy(in: source.bounds, afterScreenUpdates: true)
        }
        let edge = ConversationTopEdgeMaterial(frame: CGRect(x: 0, y: 0, width: source.bounds.width, height: 110))
        root.view.addSubview(edge)
        edge.configure(source: source, safeTop: 62)
        edge.layoutIfNeeded()
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        let displayed = try #require(edge.image)
        let attempts = edge.captureAttempts
        let commits = edge.captureCount
        edge.setNavigationActive(true)
        for _ in 0..<40 {
            edge.invalidateContent()
            edge.refreshIfNeeded()
        }
        #expect(edge.captureAttempts == attempts, "Dragging must not snapshot the hierarchy on each navigation sample")
        #expect(edge.image === displayed, "The visible owner retains its already-rendered glass while transported")
        edge.setNavigationActive(false)
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        #expect(edge.captureAttempts == attempts + 1 && edge.captureCount == commits + 1,
                "Release must consume the accumulated invalidations in one fresh sample")
    }

    @Test("native scrolling keeps rendering for the current owner before scrolling stops")
    func scrollingDoesNotStarveCurrentOwner() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let scroll = UIScrollView()
        scroll.contentSize = CGSize(width: window.bounds.width, height: 1600)
        let stripes = BlurStripeView(frame: CGRect(origin: .zero, size: scroll.contentSize))
        scroll.addSubview(stripes)
        let host = ConversationSurfaceViewController(content: BlurScrollFixture(scroll: scroll))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        driver.bind(host)
        let edge = host.topEdge
        try #require(edge.bounds.height > 0)
        // Complete the real hierarchy's first paint before exercising the
        // production scroll invalidation callback and asynchronous worker.
        _ = UIGraphicsImageRenderer(size: host.contentController.view.bounds.size).image { _ in
            _ = host.contentController.view.drawHierarchy(in: host.contentController.view.bounds, afterScreenUpdates: true)
        }
        for sample in 1...3 {
            let before = edge.captureCount
            driver.invalidateTopEdge?()
            edge.refreshIfNeeded()
            try #require(edge.renderTaskForTesting != nil)
            scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(sample) * 24), animated: false)
            driver.invalidateTopEdge?()
            await edge.awaitRenderForTesting()
            #expect(edge.captureCount > before,
                "content changes during a pending render must not prevent all visible-owner commits")
            #expect(edge.image != nil)
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func actualPixelsTaperAndRespectAppearance(style: UIUserInterfaceStyle) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.overrideUserInterfaceStyle = style
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        root.view.layoutIfNeeded()
        let source = BlurStripeView(frame: root.view.bounds)
        root.view.addSubview(source)
        // Flush this fixture's paint before exercising the production capture,
        // which intentionally avoids forcing synchronous screen updates.
        _ = UIGraphicsImageRenderer(size: source.bounds.size).image { _ in
            _ = source.drawHierarchy(in: source.bounds, afterScreenUpdates: true)
        }
        let edge = ConversationTopEdgeMaterial(frame: CGRect(x: 0, y: 0, width: source.bounds.width, height: 110))
        root.view.addSubview(edge)
        edge.configure(source: source, safeTop: 62)
        edge.layoutIfNeeded()
        let start = CFAbsoluteTimeGetCurrent()
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        let image = try #require(edge.image)
        #expect(edge.captureCount == 1)
        let top = try variance(image, y: 20)
        let bottom = try variance(image, y: 108)
        #expect(bottom > 0.01, "the bottom must retain the source's detail")
        #expect(top < bottom * 0.3, "blur radius must taper rather than merely fading a constant material")
        let background = try pixels(image, rect: CGRect(x: source.bounds.width - 8, y: 30, width: 2, height: 2))
        let brightness = background.reduce(0, +) / Double(background.count)
        #expect(style == .dark ? brightness < 0.1 : brightness > 0.9)
        print("TOP_EDGE_RENDER style=\(style.rawValue);captureMs=\((CFAbsoluteTimeGetCurrent() - start) * 1000);topVariance=\(top);bottomVariance=\(bottom);background=\(brightness)")
        edge.layoutIfNeeded()
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        #expect(edge.captureCount == 1, "idle layout must reuse the strip")
        edge.invalidate()
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        #expect(edge.captureCount == 2)
        edge.invalidateContent()
        edge.refreshIfNeeded()
        let oldTheme = try #require(edge.renderTaskForTesting)
        window.overrideUserInterfaceStyle = style == .light ? .dark : .light
        root.view.layoutIfNeeded()
        // UIKit applies its trait notifications as part of the native update.
        // Flush that update before checking cancellation, not just the request.
        source.setNeedsDisplay()
        _ = UIGraphicsImageRenderer(size: root.view.bounds.size).image { _ in
            _ = root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        #expect(edge.traitCollection.userInterfaceStyle == window.overrideUserInterfaceStyle)
        #expect(oldTheme.isCancelled, "theme changes must cancel the pending old-theme snapshot")
        await oldTheme.value
        #expect(edge.captureCount == 2 && edge.image == nil)
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        let newTheme = try #require(edge.image)
        let changedPixels = try pixels(newTheme,
            rect: CGRect(x: source.bounds.width - 8, y: 30, width: 2, height: 2))
        let changedBrightness = changedPixels.reduce(0, +) / Double(changedPixels.count)
        #expect(style == .light ? changedBrightness < 0.1 : changedBrightness > 0.9)
        #expect(edge.captureCount == 3)
        edge.invalidate()
        edge.refreshIfNeeded()
        edge.setWorkspaceVisible(false)
        await edge.awaitRenderForTesting()
        edge.refreshIfNeeded()
        #expect(edge.image == nil && edge.captureCount == 3,
            "a pending result must not repaint a hidden or detached owner")
        edge.setWorkspaceVisible(true)
        edge.refreshIfNeeded()
        let pending = try #require(edge.renderTaskForTesting)
        edge.removeFromSuperview()
        #expect(pending.isCancelled, "a detached owner must release its pending worker slot")
        await pending.value
        #expect(edge.image == nil && edge.captureCount == 3)
    }

    private func variance(_ image: UIImage, y: CGFloat) throws -> Double {
        let values = try pixels(image, rect: CGRect(x: 30, y: y, width: 140, height: 1))
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    private func pixels(_ image: UIImage, rect: CGRect) throws -> [Double] {
        let original = try #require(image.cgImage)
        let scaled = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
            width: rect.width * image.scale, height: rect.height * image.scale).integral
        let patch = try #require(original.cropping(to: scaled))
        var bytes = [UInt8](repeating: 0, count: patch.width * patch.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: patch.width, height: patch.height,
                bitsPerComponent: 8, bytesPerRow: patch.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
            return true
        }
        try #require(drawn)
        return stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
    }
}

@MainActor
private struct BlurScrollFixture: UIViewRepresentable {
    let scroll: UIScrollView
    func makeUIView(context: Context) -> UIScrollView { scroll }
    func updateUIView(_ view: UIScrollView, context: Context) {}
}
