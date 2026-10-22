#if DEBUG
import SwiftUI
import UIKit

/// Temporary observation only. Both cases assert that Settings' center is this
/// measured iPhone fixture point before interpreting the native ancestry.
struct SidebarAXNativeProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> SidebarAXNativeProbeView {
        let view = SidebarAXNativeProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "sidebar-native-hit-probe"
        view.accessibilityLabel = "Native Sidebar hit diagnostic"
        return view
    }

    func updateUIView(_ uiView: SidebarAXNativeProbeView, context: Context) {}
}

final class SidebarAXNativeProbeView: UIView {
    override var accessibilityValue: String? {
        get {
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

/// Same unchanged Rail and measured layout as the earlier semantic GREEN.
@MainActor
struct SidebarAXNativeIsolationFixture: View {
    @State private var receivedSettings = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                SidebarRailView(availableRoutes: [.search, .files, .settings],
                    conversationActions: [.new, .recent], settingsLeadingShift: 14,
                    onSelect: { if $0 == .settings { receivedSettings = true } })
                    .padding(.horizontal, 16)
                    .padding(.top, 74)
                    .padding(.bottom, 34)
                    .frame(width: 96, height: geometry.size.height)
                if receivedSettings {
                    Text("Settings action received")
                        .accessibilityIdentifier("sidebar-isolated-settings-receipt")
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea()
        .background(alignment: .topLeading) {
            SidebarAXNativeProbe().frame(width: 1, height: 1).allowsHitTesting(false)
        }
    }
}
#endif
