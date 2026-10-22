#if DEBUG
import SwiftUI
import UIKit

/// Temporary observer-effect controls. The active arm preserves the previous
/// getter exactly; passive arms return before any hit or AX property reads.
struct SidebarAXNativeProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> SidebarAXNativeProbeView {
        let view = SidebarAXNativeProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = ProcessInfo.processInfo.environment["ZEN_SIDEBAR_AX_PROBE_MODE"] != "passive-native"
        view.accessibilityIdentifier = "sidebar-native-hit-probe"
        view.accessibilityLabel = "Native Sidebar hit diagnostic"
        return view
    }

    func updateUIView(_ uiView: SidebarAXNativeProbeView, context: Context) {}
}

final class SidebarAXNativeProbeView: UIView {
    override var accessibilityValue: String? {
        get {
            let mode = ProcessInfo.processInfo.environment["ZEN_SIDEBAR_AX_PROBE_MODE"]
            if mode == "passive-native" || mode == "passive-ax" { return "passive" }
            guard let window, let screen = window.windowScene?.screen else { return "no-window" }
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
                    "interaction": current.isUserInteractionEnabled,
                    "axElement": current.isAccessibilityElement,
                    "axHidden": current.accessibilityElementsHidden,
                    "axTraits": current.accessibilityTraits.rawValue,
                    "axFrame": String(describing: current.accessibilityFrame),
                    "axActivation": String(describing: current.accessibilityActivationPoint)
                ])
                node = current.superview
            }
            let result: [String: Any] = ["sampleX": screenPoint.x, "sampleY": screenPoint.y,
                "event": "nil",
                "windowPoint": String(describing: point),
                "windowIdentity": String(describing: ObjectIdentifier(window)),
                "windowBounds": String(describing: window.bounds),
                "windowLevel": window.windowLevel.rawValue, "keyWindow": window.isKeyWindow,
                "screenBounds": String(describing: screen.bounds), "chain": chain]
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                  let value = String(data: data, encoding: .utf8) else { return "encoding-failed" }
            return value
        }
        set {}
    }
}

#endif
