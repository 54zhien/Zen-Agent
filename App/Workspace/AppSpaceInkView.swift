import Combine
import SwiftUI
import UIKit

@MainActor
struct AppSpaceInkView: View {
    let appearance: AppearanceSettings?
    let isAppSpace: Bool
    let displacement: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Initial readings precede notification registration; no per-frame polling.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        let dark = colorScheme == .dark
        InkCanvas(policy: .resolve(enabled: isAppSpace && dark && (appearance?.inkEnabled ?? true),
            intensity: appearance?.inkIntensity ?? 0.45, offset: displacement,
            reduceMotion: reduceMotion, lowPower: lowPower, thermal: thermal,
            sceneActive: scenePhase == .active), dark: dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(!inkUITestProbeEnabled)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: RunLoop.main)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: RunLoop.main)) { _ in
                thermal = ProcessInfo.processInfo.thermalState
            }
    }
}

@MainActor
private struct InkCanvas: UIViewRepresentable {
    let policy: AppSpaceMotionPolicy
    let dark: Bool
    func makeUIView(context: Context) -> AppSpaceInkNativeView { AppSpaceInkNativeView() }
    func updateUIView(_ uiView: AppSpaceInkNativeView, context: Context) {
        uiView.configure(policy: policy, dark: dark)
    }
}

@MainActor
final class AppSpaceInkNativeView: UIView {
    private let ink = CALayer()
    private let gradients = [CAGradientLayer(), CAGradientLayer()]
    private var policy = AppSpaceMotionPolicy.resolve(enabled: false, intensity: 0,
        offset: 0, reduceMotion: false, lowPower: false, thermal: .nominal, sceneActive: false)
    private var dark = false
    private var flowing = false
    private static let flowKey = "zen-ink-flow"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = !inkUITestProbeEnabled
        ink.name = "zen-app-space-ink"
        layer.addSublayer(ink)
        for (index, gradient) in gradients.enumerated() {
            gradient.name = "zen-app-space-ink-\(index)"
            gradient.type = .radial
            gradient.startPoint = index == 0 ? CGPoint(x: 0.18, y: 0.3) : CGPoint(x: 0.78, y: 0.72)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.locations = [0, 0.55, 1]
            gradient.colors = [UIColor(red: 0.09, green: 0.098, blue: 0.11, alpha: 1).cgColor,
                UIColor(red: 0.055, green: 0.061, blue: 0.07, alpha: 0.7).cgColor,
                UIColor.clear.cgColor]
            ink.addSublayer(gradient)
        }
#if DEBUG
        if inkUITestProbeEnabled {
            let probe = InkNativeProbe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            probe.renderer = self
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "app-space-ink-probe"
            probe.isUserInteractionEnabled = false
            addSubview(probe)
        }
#endif
        configure(policy: policy, dark: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(policy: AppSpaceMotionPolicy, dark: Bool) {
        self.policy = policy
        self.dark = dark
        overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundColor = dark ? UIColor(red: 0.035, green: 0.039, blue: 0.049, alpha: 1) : UIColor(red: 0.24, green: 0.25, blue: 0.28, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.isHidden = !dark || !policy.showsInk
        ink.transform = CATransform3DMakeTranslation(ink.isHidden ? 0 : CGFloat(policy.displacement), 0, 0)
        for gradient in gradients { gradient.opacity = Float(policy.intensity * 0.65) }
        CATransaction.commit()
        refreshFlow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Overscan exceeds the four-point parallax cap without a live blur/mask.
        ink.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width + 16, height: bounds.height + 16))
        ink.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for gradient in gradients { gradient.frame = ink.bounds }
        CATransaction.commit()
        refreshFlow()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFlow()
    }

    private func refreshFlow() {
        let admitted = dark && policy.flows && window != nil && bounds.width > 0 && bounds.height > 0
        guard admitted != flowing else { return }
        flowing = admitted
        for (index, gradient) in gradients.enumerated() {
            if !admitted {
                // Keep the actual displayed Ink pose when a live policy freezes it.
                let frozen = (gradient.presentation() as? CAGradientLayer)?.startPoint ?? gradient.startPoint
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                gradient.startPoint = frozen
                gradient.removeAnimation(forKey: Self.flowKey)
                CATransaction.commit()
            } else {
                let flow = CABasicAnimation(keyPath: "startPoint")
                flow.fromValue = NSValue(cgPoint: gradient.startPoint)
                let anchor = index == 0 ? CGPoint(x: 0.22, y: 0.34) : CGPoint(x: 0.74, y: 0.68)
                flow.toValue = NSValue(cgPoint: anchor)
                flow.duration = index == 0 ? 22 : 29
                flow.beginTime = gradient.convertTime(CACurrentMediaTime(), from: nil)
                flow.autoreverses = true
                flow.repeatCount = .infinity
                flow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gradient.add(flow, forKey: Self.flowKey)
            }
        }
    }

#if DEBUG
    var diagnostic: String {
        let keys = gradients.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
        return "ink=\(!ink.isHidden);layers=\(ink.sublayers?.count ?? 0);flowRequested=\(dark && policy.flows);flowKeys=\(keys);nativeWindow=\(window != nil);"
    }
#endif
}

@MainActor
private var inkUITestProbeEnabled: Bool {
#if DEBUG
    ProcessInfo.processInfo.environment["ZEN_INK_UI_TEST"] == "1"
#else
    false
#endif
}

#if DEBUG
@MainActor
private final class InkNativeProbe: UIView {
    weak var renderer: AppSpaceInkNativeView?
    override var accessibilityValue: String? {
        get { renderer?.diagnostic ?? "unbound" }
        set { super.accessibilityValue = newValue }
    }
}
#endif
