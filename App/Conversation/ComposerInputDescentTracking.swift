import UIKit

/// Follows the existing sheet animation instead of starting a second clock with
/// a guessed duration. The owner decides when to release its input reservation.
@MainActor
final class ComposerInputDescentTracking: NSObject {
    private weak var sheet: UIView?
    private let startTranslation: CGFloat
    private let endTranslation: CGFloat
    private let onProgress: (CGFloat) -> Void
    private var displayLink: CADisplayLink?
    private var progress: CGFloat = 0

    init(sheet: UIView, travel: CGFloat, onProgress: @escaping (CGFloat) -> Void) {
        self.sheet = sheet
        startTranslation = sheet.layer.presentation()?.affineTransform().ty ?? sheet.transform.ty
        endTranslation = travel
        self.onProgress = onProgress
        super.init()
        let target = ComposerInputDescentTick(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(ComposerInputDescentTick.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func tick() {
        // A missing presentation layer is not proof of arrival: model-layer
        // transforms already contain the destination before the first frame.
        guard let sheet, sheet.window != nil, let layer = sheet.layer.presentation() else { return }
        let distance = endTranslation - startTranslation
        guard distance > 0.5 else { return }
        progress = max(progress, min(1, max(0, (layer.affineTransform().ty - startTranslation) / distance)))
        onProgress(progress)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

@MainActor
private final class ComposerInputDescentTick: NSObject {
    private weak var owner: ComposerInputDescentTracking?
    init(owner: ComposerInputDescentTracking) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick()
    }
}
