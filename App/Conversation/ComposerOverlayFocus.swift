import UIKit

/// A capability for the actual responder, never a replacement editor or a
/// remembered logical focus flag. Both the host and its original window are weak.
@MainActor
final class ComposerOverlayFocus {
    weak var host: ComposerHostView?
    weak var window: UIWindow?
    private let ownerIsCurrent: () -> Bool
    private(set) var cancelled = false

    init(host: ComposerHostView, window: UIWindow, ownerIsCurrent: @escaping () -> Bool) {
        self.host = host; self.window = window; self.ownerIsCurrent = ownerIsCurrent
    }

    var isValid: Bool { !cancelled && host != nil && window != nil && ownerIsCurrent() }

    func restore() {
        guard isValid else { cancel(); return }
        host?.queueOverlayFocus(self)
    }

    func cancel() {
        cancelled = true
        host?.cancelOverlayFocus(self)
    }
}
