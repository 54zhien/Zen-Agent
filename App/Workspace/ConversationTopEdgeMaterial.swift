import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Samples only the retained content sibling, never this decoration or the window.
/// Content/layout invalidation drives captures; an unchanged page reuses its strip.
@MainActor
final class ConversationTopEdgeMaterial: UIImageView {
    static let fadeHeight: CGFloat = 48
    private static let worker = TopEdgeBlurWorker()
    private weak var source: UIView?
    private var contentOwner: ObjectIdentifier?
    private var safeTop: CGFloat = 0
    private var visible = true
    private var suspended = false
    private var dirty = true
    private var renderer: UIGraphicsImageRenderer?
    private var rendererSize = CGSize.zero
    private var rendererScale: CGFloat = 0
    private var lastBounds = CGRect.zero
    private var revision: UInt64 = 0
    private var renderTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private let clockTarget = TopEdgeDisplayLinkTarget()
    private let fade = CAGradientLayer()
    private(set) var captureCount = 0
    private(set) var captureAttempts = 0
    private(set) var captureFailures = 0
    private(set) var lastCaptureMilliseconds = 0.0
    private(set) var lastRenderMilliseconds = 0.0
#if DEBUG
    func awaitRenderForTesting() async { await renderTask?.value }
    var renderTaskForTesting: Task<Void, Never>? { renderTask }
    var beforeRenderForTesting: (@MainActor () async -> Void)?
    var sourceIdentityForTesting: ObjectIdentifier? { source.map(ObjectIdentifier.init) }
    var samplingDiagnostic: String {
        "topEdgePending=\(renderTask != nil);topEdgeDirty=\(dirty);topEdgeScrollCaptures=\(scrollCaptureCount);topEdgeScrollFrameIntervals=\(scrollFrameIntervals);topEdgeScrollMeanGapMs=\(scrollFrameIntervals > 0 ? scrollFrameTotalMs / Double(scrollFrameIntervals) : 0);topEdgeScrollMaxGapMs=\(scrollFrameMaxMs)"
    }
    var scrolling = false {
        didSet {
            guard scrolling != oldValue else { return }
            scrollFrameLink?.invalidate(); scrollFrameLink = nil
            lastScrollFrame = nil
            guard scrolling, window != nil else { return }
            scrollFrameIntervals = 0; scrollFrameTotalMs = 0; scrollFrameMaxMs = 0
            let link = CADisplayLink(target: clockTarget, selector: #selector(TopEdgeDisplayLinkTarget.scrollFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            scrollFrameLink = link
        }
    }
    private var scrollFrameLink: CADisplayLink?
    private var lastScrollFrame: CFTimeInterval?
    private var scrollFrameIntervals = 0
    private var scrollFrameTotalMs = 0.0
    private var scrollFrameMaxMs = 0.0
    func recordScrollFrame(_ link: CADisplayLink) {
        guard scrolling else { link.invalidate(); return }
        if let previous = lastScrollFrame {
            let gap = (link.timestamp - previous) * 1000
            scrollFrameIntervals += 1
            scrollFrameTotalMs += gap
            scrollFrameMaxMs = max(scrollFrameMaxMs, gap)
        }
        lastScrollFrame = link.timestamp
    }
    private var scrollCaptureCount = 0
#endif

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

    func setContentOwner(_ value: ObjectIdentifier?) {
        guard contentOwner != value else { return }
        contentOwner = value
#if DEBUG
        scrolling = false
#endif
        invalidate()
    }

    func setWorkspaceVisible(_ value: Bool) {
        guard visible != value else { updateClock(); return }
        visible = value
#if DEBUG
        if !value { scrolling = false }
#endif
        if !value { image = nil; renderTask?.cancel() }
        invalidate()
    }

    // Owner, theme and output geometry changes invalidate pending pixels.
    func invalidate() {
        revision &+= 1
        image = nil
        renderTask?.cancel()
        dirty = true
        updateClock()
    }

    // Content changes request the next sample without starving the in-flight
    // snapshot of this same visible owner during continuous native scrolling.
    func invalidateContent() { dirty = true; updateClock() }
    @objc private func pause() {
        suspended = true
#if DEBUG
        scrolling = false
#endif
        updateClock()
    }
    @objc private func resume() { suspended = false; invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
#if DEBUG
        if window == nil { scrolling = false }
#endif
        if window == nil { image = nil; renderTask?.cancel() }
        invalidate()
    }
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
        let active = dirty && renderTask == nil && visible && !suspended && window != nil && source?.window === window
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
        guard dirty, renderTask == nil, visible, !suspended, let source, let window,
              source.window === window, bounds.width > 0, bounds.height > 0 else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        // A failed snapshot consumes its invalidation too. Only a new content,
        // layout or theme event may retry, never an idle display-link loop.
        dirty = false
        defer { updateClock() }
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
        // The strip is blurred rather than read as text. Point-resolution
        // sampling bounds snapshot and convolution work; the final alpha fade
        // reveals the original Retina content without a sharp resampling seam.
        let scale: CGFloat = 1
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
        guard complete, let input = captured.cgImage else {
            image = nil
            backgroundColor = color
            return
        }
        let ticket = revision
        let sourceID = ObjectIdentifier(source)
        let windowID = ObjectIdentifier(window)
        let frame = bounds
        let payload = TopEdgeBlurInput(image: input, safeTop: safeTop, height: bounds.height,
            captureHeight: size.height, scale: scale)
#if DEBUG
        let beforeRender = beforeRenderForTesting
        let capturedWhileScrolling = scrolling
#endif
        renderTask = Task { [weak self] in
#if DEBUG
            await beforeRender?()
#endif
            let result = await Self.worker.render(payload)
            guard let self else { return }
            self.renderTask = nil
            defer { self.updateClock() }
            guard !Task.isCancelled, self.visible, !self.suspended, self.revision == ticket,
                  self.source.map(ObjectIdentifier.init) == sourceID,
                  self.window.map(ObjectIdentifier.init) == windowID, self.bounds == frame else { return }
            guard let result else {
                self.image = nil
                self.backgroundColor = .systemBackground
                return
            }
            self.image = UIImage(cgImage: result.image, scale: scale, orientation: .up)
            self.lastRenderMilliseconds = result.milliseconds
            self.captureCount += 1
#if DEBUG
            if capturedWhileScrolling && self.scrolling { self.scrollCaptureCount += 1 }
#endif
        }
    }
}

// CGImage is an immutable, retained snapshot. No UIView, CGContext or mutable
// bitmap storage crosses from the main actor to the serial image worker.
private struct TopEdgeBlurInput: @unchecked Sendable {
    let image: CGImage
    let safeTop: CGFloat
    let height: CGFloat
    let captureHeight: CGFloat
    let scale: CGFloat
}

private struct TopEdgeBlurOutput: @unchecked Sendable {
    let image: CGImage
    let milliseconds: Double
}

private actor TopEdgeBlurWorker {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ input: TopEdgeBlurInput) -> TopEdgeBlurOutput? {
        guard !Task.isCancelled else { return nil }
        let start = CACurrentMediaTime()
        let original = CIImage(cgImage: input.image)
        let extra = max(0, input.captureHeight - input.height) * input.scale
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: extra)
        gradient.point1 = CGPoint(x: 0, y: max(extra + 1, input.captureHeight * input.scale - input.safeTop * input.scale))
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = original.clampedToExtent()
        blur.mask = gradient.outputImage?.cropped(to: original.extent)
        blur.radius = Float(16 * input.scale)
        let crop = CGRect(x: 0, y: extra, width: original.extent.width, height: input.height * input.scale)
        guard let output = blur.outputImage, !Task.isCancelled,
              let rendered = context.createCGImage(output, from: crop), !Task.isCancelled else { return nil }
        return TopEdgeBlurOutput(image: rendered, milliseconds: (CACurrentMediaTime() - start) * 1000)
    }
}

@MainActor
private final class TopEdgeDisplayLinkTarget: NSObject {
    weak var owner: ConversationTopEdgeMaterial?
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.refreshIfNeeded()
    }
#if DEBUG
    @objc func scrollFrame(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.recordScrollFrame(link)
    }
#endif
}
