import Testing
import UIKit
@testable import ZenAgent

@MainActor
private final class DividerInitialTouch: UITouch {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class DividerSamplePan: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { .zero }
}

@MainActor
@Suite("Divider initial touch displacement", .serialized)
struct SplitDividerInteractionTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func sidebarProgressTintsTheNativeHandleAndFadesItsShadow(style: UIUserInterfaceStyle) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.overrideUserInterfaceStyle = style
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.backgroundColor = UIColor(white: 0.5, alpha: 1)
        let divider = SplitDividerHandle(frame: CGRect(x: 100, y: 300, width: 64, height: 28))
        controller.view.addSubview(divider)
        defer { window.isHidden = true; window.rootViewController = nil }

        divider.configuration = SplitDividerView(ratio: 0.5, closeIntent: nil,
            canCloseTop: true, canCloseBottom: true, onBegin: { true },
            onMove: { _ in }, onEnd: { _ in }, onClose: { _ in }, onAdjust: { _ in },
            gutterSize: CGSize(width: 400, height: 10))
        divider.layoutIfNeeded()
        let nativeHandle = try #require(divider.subviews.first {
            $0.layer.name == "zen-split-divider-handle"
        })
        let shadow = try #require(divider.subviews.first {
            $0.layer.name == "zen-split-divider-handle-shadow"
        })
        let gutter = try #require(divider.subviews.first {
            $0.layer.name == "zen-split-divider-gutter"
        })
        let hitBounds = divider.bounds
        let handleFrame = nativeHandle.frame
        var luminance: [CGFloat] = []

        for progress in [CGFloat(0), 0.5, 1] {
            divider.configuration = SplitDividerView(ratio: 0.5, closeIntent: nil,
                canCloseTop: true, canCloseBottom: true, onBegin: { true },
                onMove: { _ in }, onEnd: { _ in }, onClose: { _ in }, onAdjust: { _ in },
                sidebarProgress: progress, gutterSize: CGSize(width: 400, height: 10))
            divider.layoutIfNeeded()
            let color = try #require(nativeHandle.backgroundColor?.resolvedColor(with: divider.traitCollection))
            var red: CGFloat = 1
            var green: CGFloat = 1
            var blue: CGFloat = 1
            var alpha: CGFloat = 1
            #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            let brightness = (red + green + blue) / 3
            luminance.append(brightness)
            #expect(alpha == 1)
            if style == .light {
                #expect(red > 0.98 && green > 0.98 && blue > 0.98,
                    "In Light appearance the handle blends into the light page surface")
            }
            #expect(nativeHandle.alpha == 1)
            #expect(divider.alpha == 1)
            #expect(shadow.alpha == progress)
            #expect(gutter.alpha == 1 - progress)
            #expect(gutter.frame == CGRect(x: -168, y: 9, width: 400, height: 10))
            #expect(divider.hitTest(CGPoint(x: -10, y: 14), with: nil) == nil,
                "The full-width decorative gutter must not extend the native divider hit area")
            #expect(!shadow.isHidden)
            #expect(shadow.frame == nativeHandle.frame)
            #expect(shadow.layer.shadowPath != nil)
            #expect(shadow.layer.shadowOffset == CGSize(width: 0, height: 1))
            #expect(abs(shadow.layer.shadowOpacity - 0.14) < 0.001)
            #expect(divider.bounds == hitBounds && nativeHandle.frame == handleFrame,
                "Sidebar styling must preserve the 28pt divider hit area and handle geometry")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let capture = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image {
                controller.view.layer.render(in: $0.cgContext)
            }
            let pixel = try #require(capture.cgImage?.cropping(to: CGRect(x: 90, y: 314, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            try #require(rendered)
            #expect(abs(Double(rgba[0]) / 255 - 0.5) < 0.02,
                "Outside the handle and its shadow, the gap must reveal its actual backdrop without an extra dark layer")
        }
        if style == .dark {
            #expect(luminance[0] > 0.98)
            #expect(luminance[0] > luminance[1] && luminance[1] > luminance[2],
                "The native handle should transition smoothly toward the dark page surface")
            #expect(luminance[2] < 0.15,
                "The fully open handle should match the dark Sidebar page surface")
        }
    }

    @Test(arguments: [SplitWorkspaceAxis.topBottom, .leftRight])
    func coalescedPanRetainsMovementBeforeRecognition(axis: SplitWorkspaceAxis) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let handle = SplitDividerHandle(frame: CGRect(x: 100, y: 300, width: 64, height: 28))
        window.addSubview(handle)
        var moves: [Double] = []
        var endings: [Bool] = []
        handle.configuration = SplitDividerView(ratio: 0.5, closeIntent: nil,
            canCloseTop: true, canCloseBottom: true, onBegin: { true },
            onMove: { moves.append($0) }, onEnd: { endings.append($0) },
            onClose: { _ in }, onAdjust: { _ in }, axis: axis)
        let installed = try #require(handle.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let origin = CGPoint(x: 132, y: 314)
        let touch = DividerInitialTouch(point: origin)
        #expect(installed.delegate?.gestureRecognizer?(installed, shouldReceive: touch) ?? true)
        let sample = DividerSamplePan()
        sample.point = axis == .leftRight ? CGPoint(x: origin.x + 100, y: origin.y)
            : CGPoint(x: origin.x, y: origin.y + 100)
        sample.sampleState = .began
        _ = handle.perform(NSSelectorFromString("panned:"), with: sample)
        // The moving handle is not the coordinate owner of this gesture.
        handle.frame.origin.x += 70
        handle.frame.origin.y += 50
        sample.sampleState = .ended
        _ = handle.perform(NSSelectorFromString("panned:"), with: sample)
        #expect(moves == [100, 100])
        #expect(endings == [false])
    }
}
