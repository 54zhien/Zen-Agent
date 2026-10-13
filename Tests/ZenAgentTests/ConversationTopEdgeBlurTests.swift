import UIKit
import Testing
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
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func actualPixelsTaperAndRespectAppearance(style: UIUserInterfaceStyle) throws {
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
        #expect(edge.captureCount == 1, "idle layout must reuse the strip")
        edge.invalidate()
        edge.refreshIfNeeded()
        #expect(edge.captureCount == 2)
        edge.setWorkspaceVisible(false)
        edge.refreshIfNeeded()
        #expect(edge.image == nil && edge.captureCount == 2)
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

