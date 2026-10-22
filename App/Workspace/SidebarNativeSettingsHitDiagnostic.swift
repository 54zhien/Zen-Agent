#if DEBUG
import UIKit

/// Temporary physical sampling through the existing diagnostic channel. No
/// representable, AX metadata read, layout update, or synthetic event is added.
@MainActor
enum SidebarNativeSettingsHitDiagnostic {
    static func capture(window: UIWindow, host: UIViewController, context: [String: Any]) -> String {
        guard let screen = window.windowScene?.screen else { return "no-screen" }
        let screenPoint = CGPoint(x: 62, y: 812)
        let point = screen.coordinateSpace.convert(screenPoint, to: window)
        var node = window.hitTest(point, with: nil)
        var chain: [[String: Any]] = []
        while let current = node, chain.count < 24 {
            let local = current.convert(point, from: window)
            chain.append([
                "type": String(describing: type(of: current)),
                "frame": String(describing: current.frame),
                "windowFrame": String(describing: current.convert(current.bounds, to: window)),
                "bounds": String(describing: current.bounds),
                "transform": String(describing: current.transform),
                "pointInside": current.point(inside: local, with: nil),
                "clips": current.clipsToBounds,
                "hidden": current.isHidden,
                "alpha": current.alpha,
                "interaction": current.isUserInteractionEnabled
            ])
            node = current.superview
        }
        let result: [String: Any] = [
            "sampleX": screenPoint.x, "sampleY": screenPoint.y, "sampleCount": 1,
            "event": "nil", "windowPoint": String(describing: point),
            "hostIdentity": String(describing: ObjectIdentifier(host)),
            "windowIdentity": String(describing: ObjectIdentifier(window)),
            "windowBounds": String(describing: window.bounds),
            "windowLevel": window.windowLevel.rawValue, "keyWindow": window.isKeyWindow,
            "screenBounds": String(describing: screen.bounds),
            "state": "foreground-full-visible-open-settled", "context": context, "chain": chain
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "encoding-failed" }
        return value
    }
}
#endif
