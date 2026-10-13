import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Samples only the retained content sibling, never this decoration or the window.
/// Content/layout invalidation drives captures; an unchanged page reuses its strip.
@MainActor
final class ConversationTopEdgeMaterial: UIImageView {
    static let fadeHeight: CGFloat = 48
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private weak var source: UIView?
    private var safeTop: CGFloat = 0
    private var visible = true
    private var suspended = false
    private var dirty = true
    private var renderer: UIGraphicsImageRenderer?
    private var rendererSize = CGSize.zero
    private var rendererScale: CGFloat = 0
    private var lastBounds = CGRect.zero
    private var displayLink: CADisplayLink?
    private let clockTarget = TopEdgeDisplayLinkTarget()
    private let fade = CAGradientLayer()
    private(set) var captureCount = 0
    private(set) var captureAttempts = 0
    private(set) var captureFailures = 0
    private(set) var lastCaptureMilliseconds = 0.0
    private(set) var lastRenderMilliseconds = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        contentMode = .scaleToFill
        clockTarget.owner = self
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.85, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fade
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (view: ConversationTopEdgeMaterial, _: UITraitCollection) in view.invalidate()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pause),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(source: UIView, safeTop: CGFloat) {
        if self.source !== source || self.safeTop != safeTop {
            self.source = source
            self.safeTop = safeTop
            invalidate()
        }
        updateClock()
    }

    func setWorkspaceVisible(_ value: Bool) {
        guard visible != value else { updateClock(); return }
        visible = value
        if !value { image = nil }
        invalidate()
    }

    func invalidate() { dirty = true; updateClock() }
    @objc private func pause() { suspended = true; updateClock() }
    @objc private func resume() { suspended = false; invalidate() }

    override func didMoveToWindow() { super.didMoveToWindow(); invalidate() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let changed = lastBounds != bounds
        fade.frame = bounds
        lastBounds = bounds
        CATransaction.commit()
        if changed { invalidate() }
    }

    private func updateClock() {
        let active = visible && !suspended && window != nil && source?.window === window
            && UIApplication.shared.applicationState == .active
            && bounds.width > 0 && bounds.height > 0 && safeTop > 0
        guard active else { displayLink?.invalidate(); displayLink = nil; return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: clockTarget, selector: #selector(TopEdgeDisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func refreshIfNeeded() {
        guard dirty, visible, !suspended, let source, let window,
              source.window === window, bounds.width > 0, bounds.height > 0 else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        let color = UIColor.systemBackground.resolvedColor(with: source.traitCollection)
        if UIAccessibility.isReduceTransparencyEnabled {
            image = nil
            backgroundColor = color
            dirty = false
            return
        }
        backgroundColor = .clear
        // Convolution reads real content below the fade instead of smearing a
        // cropped edge. A modest strip bounds both capture and GPU allocation.
        let size = CGSize(width: bounds.width, height: min(source.bounds.height, bounds.height + 32))
        let scale = window.screen.scale
        if rendererSize != size || rendererScale != scale {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            renderer = UIGraphicsImageRenderer(size: size, format: format)
            rendererSize = size
            rendererScale = scale
        }
        guard let renderer else { return }
        var complete = false
        captureAttempts += 1
        let captureStart = CACurrentMediaTime()
        let captured = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            complete = source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }
        lastCaptureMilliseconds = (CACurrentMediaTime() - captureStart) * 1000
        if !complete { captureFailures += 1 }
        guard complete, let input = captured.cgImage else { return }
        let renderStart = CACurrentMediaTime()
        let original = CIImage(cgImage: input)
        let extra = max(0, size.height - bounds.height) * scale
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: extra)
        gradient.point1 = CGPoint(x: 0, y: max(extra + 1, size.height * scale - safeTop * scale))
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = original.clampedToExtent()
        blur.mask = gradient.outputImage?.cropped(to: original.extent)
        blur.radius = Float(16 * scale)
        let crop = CGRect(x: 0, y: extra, width: original.extent.width, height: bounds.height * scale)
        guard let output = blur.outputImage,
              let rendered = Self.context.createCGImage(output, from: crop) else { return }
        image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        lastRenderMilliseconds = (CACurrentMediaTime() - renderStart) * 1000
        captureCount += 1
        dirty = false
    }
}

@MainActor
private final class TopEdgeDisplayLinkTarget: NSObject {
    weak var owner: ConversationTopEdgeMaterial?
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.refreshIfNeeded()
    }
}
