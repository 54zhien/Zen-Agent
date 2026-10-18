#if DEBUG
import SwiftUI
import UIKit

/// Runs native focus reversals without XCTest's animation-idle waits. Geometry
/// samples come from presentation layers; this does not inspect rendered pixels.
@MainActor
struct SplitKeyboardStressProbe: UIViewRepresentable {
    let driver: SurfaceLiftController
    let axis: SplitWorkspaceAxis
    let ratio: Double

    func makeUIView(context: Context) -> SplitKeyboardStressView { SplitKeyboardStressView() }
    func updateUIView(_ view: SplitKeyboardStressView, context: Context) {
        view.composer = { [weak driver] in driver?.externalComposer }
        view.axis = axis
        view.ratio = ratio
    }
    static func dismantleUIView(_ view: SplitKeyboardStressView, coordinator: Void) { view.stop() }
}

@MainActor
final class SplitKeyboardStressView: UIView {
    var composer: () -> ComposerHostView? = { nil }
    var axis: SplitWorkspaceAxis = .topBottom
    var ratio = 0.5
    private let startButton = UIButton(type: .system)
    private let watchButton = UIButton(type: .system)
    private let diagnostic = UIView()
    private var task: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var status = "idle"
    private var samples = 0
    private var requests = 0
    private var missingSurfaces = 0
    private var maxUnderfill: CGFloat = 0
    private var maxPartitionError: CGFloat = 0
    private var keyboardEvents = 0
    private var retargetedEvents = 0
    private var sidebarSamples = 0
    private var overlappingSamples = 0
    private var keyboardDeadline: CFTimeInterval = 0
    private var firstKeyboardEventTime: CFTimeInterval?
    private var firstKeyboardDuration: CFTimeInterval?
    private var firstKeyboardSampleDelay: CFTimeInterval?
    private var firstValidSampleDelay: CFTimeInterval?
    private var firstSidebarSampleDelay: CFTimeInterval?
    private var observesSidebar = false
    private var captureGeneration = UUID()
    private var watchDeadline: CFTimeInterval = 0
    private var settledAnimations = "not-captured"

    override init(frame: CGRect) {
        super.init(frame: frame)
        startButton.setTitle("Stress", for: .normal)
        startButton.accessibilityIdentifier = "split-keyboard-stress-start"
        startButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        addSubview(startButton)
        watchButton.setTitle("Watch", for: .normal)
        watchButton.accessibilityIdentifier = "split-keyboard-watch-start"
        watchButton.addTarget(self, action: #selector(watch), for: .touchUpInside)
        addSubview(watchButton)
        diagnostic.isAccessibilityElement = true
        diagnostic.isUserInteractionEnabled = false
        diagnostic.accessibilityIdentifier = "split-keyboard-stress-probe"
        addSubview(diagnostic)
        publish()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        startButton.frame = CGRect(x: max(0, bounds.width - 72), y: (window?.safeAreaInsets.top ?? 0) + 44,
                                   width: 64, height: 32)
        watchButton.frame = startButton.frame.offsetBy(dx: -68, dy: 0)
        diagnostic.frame = CGRect(x: 1, y: 1, width: 1, height: 1)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for button in [startButton, watchButton] where button.frame.contains(point) {
            return button.hitTest(convert(point, to: button), with: event)
        }
        return nil
    }

    @objc private func start() {
        guard task == nil, let input = composer(), input.window === window,
              input.editor.markedTextRange == nil else { return }
        beginSampling()
        let generation = captureGeneration
        task = Task { @MainActor [weak self, weak input] in
            do {
                // Deliberately shorter than the normal transition. Real responder
                // callbacks still update the existing Composer and workspace.
                for index in 0..<12 {
                    guard let self, let input else { return }
                    guard self.captureGeneration == generation else { return }
                    guard input === self.composer(), input.window === self.window,
                          !Task.isCancelled else { self.stop(); return }
                    input.requestFocus(index.isMultiple(of: 2))
                    self.requests += 1
                    try await Task.sleep(for: .milliseconds(index.isMultiple(of: 3) ? 90 : 60))
                }
                try await Task.sleep(for: .milliseconds(600))
                guard let self, self.captureGeneration == generation, !Task.isCancelled else { return }
                self.finish()
            } catch {
                if self?.captureGeneration == generation { self?.stop() }
            }
        }
    }

    @objc private func watch() {
        guard task == nil, status != "armed", status != "running" else { return }
        beginSampling(sidebar: true)
        // XCTest may delay synthesizing the edge gesture after this tap.
        // Remain armed until a real keyboard event starts the bounded capture;
        // the UI test still times out if that event never arrives.
    }

    private func finishWatch(after duration: Duration) {
        task?.cancel()
        let generation = captureGeneration
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard let self, self.captureGeneration == generation, !Task.isCancelled else { return }
            // Simulator rendering may be heavily throttled while XCTest is
            // synthesizing an edge gesture. Require real display ticks, with a
            // deadline; never manufacture a final sample to satisfy the count.
            if self.observesSidebar, self.keyboardEvents > 0,
               self.samples < 6, CACurrentMediaTime() < self.watchDeadline {
                self.finishWatch(after: .milliseconds(250))
                return
            }
            self.finish()
        }
    }

    private func beginSampling(sidebar: Bool = false) {
        observesSidebar = sidebar
        captureGeneration = UUID()
        watchDeadline = 0
        samples = 0; requests = 0; missingSurfaces = 0
        keyboardEvents = 0; retargetedEvents = 0; sidebarSamples = 0; overlappingSamples = 0; keyboardDeadline = 0
        maxUnderfill = 0; maxPartitionError = 0; status = sidebar ? "armed" : "running"
        settledAnimations = "not-captured"
        firstKeyboardEventTime = nil; firstKeyboardDuration = nil; firstKeyboardSampleDelay = nil
        firstValidSampleDelay = nil; firstSidebarSampleDelay = nil
        startButton.isEnabled = false; watchButton.isEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Keep the presentation sampler ready before the gesture's keyboard
        // notification; creating it there can miss a short first transition.
        startDisplayLink()
        publish()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(sample))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard window != nil else { return }
        let now = CACurrentMediaTime()
        if now < keyboardDeadline { retargetedEvents += 1 }
        keyboardEvents += 1
        keyboardDeadline = now + ((notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0)
        if firstKeyboardEventTime == nil {
            firstKeyboardEventTime = now
            firstKeyboardDuration = keyboardDeadline - now
        }
        if observesSidebar {
            // XCTest can spend several seconds admitting/synthesizing the real
            // edge gesture. Arm first, then sample the keyboard event itself.
            status = "running"
            if watchDeadline == 0 { watchDeadline = now + 5 }
            guard now < watchDeadline else { finish(); return }
            startDisplayLink()
            finishWatch(after: .seconds(min(2, watchDeadline - now)))
        }
    }

    private func finish() {
        displayLink?.invalidate(); displayLink = nil
        NotificationCenter.default.removeObserver(self)
        settledAnimations = animationDiagnostic()
        status = "done"; task = nil
        startButton.isEnabled = true; watchButton.isEnabled = true
        publish()
    }

    func stop() {
        captureGeneration = UUID()
        task?.cancel(); task = nil
        displayLink?.invalidate(); displayLink = nil
        NotificationCenter.default.removeObserver(self)
        if status == "running" || status == "armed" { status = "cancelled" }
        startButton.isEnabled = true; watchButton.isEnabled = true
        publish()
    }

    @objc private func sample() {
        // Arming readies the display link without traversing the window or
        // publishing AX values while XCTest is still admitting its gesture.
        guard let window, !observesSidebar || keyboardEvents > 0 else { return }
        let now = CACurrentMediaTime()
        if firstKeyboardSampleDelay == nil, let firstKeyboardEventTime {
            firstKeyboardSampleDelay = now - firstKeyboardEventTime
        }
        func visible(_ view: UIView) -> Bool {
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.01 { return false }
                ancestor = current.superview
            }
            return view.window === window
        }
        func surfaces(_ node: UIView) -> [SurfaceClipView] {
            if let surface = node as? SurfaceClipView, visible(surface) { return [surface] }
            return node.subviews.flatMap(surfaces)
        }
        func presented(_ view: UIView) -> CGRect {
            let layer = view.layer.presentation() ?? view.layer
            return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
        }
        let mounted = surfaces(window)
        samples += 1
        guard mounted.count == 2 else { missingSurfaces += 1; publish(); return }
        if mounted.contains(where: { surface in
            guard let parent = surface.superview else { return false }
            return abs((parent.layer.presentation() ?? parent.layer).affineTransform().tx) > 0.5
        }) {
            sidebarSamples += 1
            if firstSidebarSampleDelay == nil, let firstKeyboardEventTime {
                firstSidebarSampleDelay = now - firstKeyboardEventTime
            }
            // Joint evidence from the same display tick, bounded by the timing
            // reported by UIKit; this is not a rendered keyboard-pixel sample.
            if now < keyboardDeadline { overlappingSamples += 1 }
        }
        var hosts: [CGRect] = []
        var horizontalShifts: [CGFloat] = []
        for surface in mounted {
            guard let viewport = surface.validationViewport, let content = surface.validationContent,
                  let transport = surface.superview else {
                missingSurfaces += 1; publish(); return
            }
            let host = presented(viewport), card = presented(surface), child = presented(content)
            hosts.append(host)
            horizontalShifts.append(card.minX - host.minX)
            // Only Watch admits Sidebar transport; rapid keyboard-only cycles
            // must also keep both horizontal edges pinned to the original host.
            let horizontalBounds = observesSidebar ? presented(transport) : host
            let errors = [maxUnderfill, abs(host.minY - card.minY), abs(host.maxY - card.maxY),
                abs(host.width - card.width), abs(card.minY - child.minY), abs(card.maxY - child.maxY),
                abs(card.minX - child.minX), abs(card.maxX - child.maxX),
                abs(horizontalBounds.minX - card.minX), abs(horizontalBounds.maxX - card.maxX)]
            maxUnderfill = errors.max() ?? maxUnderfill
        }
        let workspace = presented(self)
        if firstValidSampleDelay == nil, let firstKeyboardEventTime {
            firstValidSampleDelay = now - firstKeyboardEventTime
        }
        let horizontal = axis == .leftRight
        hosts.sort { horizontal ? $0.midX < $1.midX : $0.midY < $1.midY }
        let length = horizontal ? workspace.width : workspace.height
        let gap = min(SplitWorkspaceGeometry.dividerThickness, length * min(ratio, 1 - ratio))
        let actualGap = horizontal ? hosts[1].minX - hosts[0].maxX : hosts[1].minY - hosts[0].maxY
        let leading = horizontal ? hosts[0].minX - workspace.minX : hosts[0].minY - workspace.minY
        let trailing = horizontal ? hosts[1].maxX - workspace.maxX : hosts[1].maxY - workspace.maxY
        maxPartitionError = max(maxPartitionError, abs(actualGap - gap), abs(leading), abs(trailing))
        if observesSidebar, let largest = horizontalShifts.max(), let smallest = horizontalShifts.min() {
            maxPartitionError = max(maxPartitionError, largest - smallest)
        }
        publish()
    }

    private func animationDiagnostic() -> String {
        var visited: Set<ObjectIdentifier> = []
        var entries: [String] = []
        var count = 0
        func inspect(_ layer: CALayer) {
            guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                count += 1
                if entries.count < 80 {
                    let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? "CALayer"
                    let path = (animation as? CAPropertyAnimation)?.keyPath ?? "group"
                    entries.append("\(owner)/\(layer.name ?? "unnamed"):\(key):\(path):duration=\(animation.duration),repeat=\(animation.repeatCount),repeatDuration=\(animation.repeatDuration),speed=\(animation.speed),begin=\(animation.beginTime),now=\(layer.convertTime(CACurrentMediaTime(), from: nil)),layerSpeed=\(layer.speed),layerOffset=\(layer.timeOffset),removed=\(animation.isRemovedOnCompletion),fill=\(animation.fillMode.rawValue),hidden=\(layer.isHidden),bounds=\(layer.bounds)")
                }
            }
            if let mask = layer.mask { inspect(mask) }
            for child in layer.sublayers ?? [] { inspect(child) }
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows { inspect(window.layer) }
        }
        for root in ComposerHostView.animationRootsForUITesting { inspect(root.layer) }
        return "count=\(count)[\(entries.joined(separator: " | "))]"
    }

    private func publish() {
        diagnostic.accessibilityValue = "status=\(status);samples=\(samples);requests=\(requests);missing=\(missingSurfaces);underfill=\(maxUnderfill);partitionError=\(maxPartitionError);keyboardEvents=\(keyboardEvents);retargeted=\(retargetedEvents);sidebarSamples=\(sidebarSamples);overlap=\(overlappingSamples);firstKeyboardDuration=\(String(describing: firstKeyboardDuration));firstKeyboardSampleDelay=\(String(describing: firstKeyboardSampleDelay));firstValidSampleDelay=\(String(describing: firstValidSampleDelay));firstSidebarSampleDelay=\(String(describing: firstSidebarSampleDelay));settledAnimations=\(settledAnimations)"
    }
}
#endif
