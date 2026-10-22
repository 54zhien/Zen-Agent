import SwiftUI
import UIKit

@MainActor
enum ComposerInputAnimation {
    /// Publish the viewport endpoint once, then let UIKit and SwiftUI interpolate
    /// their own layout. The native Composer joins the sheet's actual animator.
    static func apply(using animator: UIViewPropertyAnimator?,
                      publishViewport: () -> Void, layoutComposer: @escaping () -> Void) {
        guard let animator else {
            publishViewport()
            layoutComposer()
            return
        }
        let remaining = animator.duration * Double(max(0, 1 - animator.fractionComplete))
        let animation: Animation
        switch animator.timingParameters?.cubicTimingParameters?.animationCurve ?? .easeInOut {
        case .easeIn: animation = .easeIn(duration: remaining)
        case .easeOut: animation = .easeOut(duration: remaining)
        case .linear: animation = .linear(duration: remaining)
        case .easeInOut: animation = .easeInOut(duration: remaining)
        @unknown default: animation = .easeInOut(duration: remaining)
        }
        withAnimation(animation, publishViewport)
        animator.addAnimations(layoutComposer)
    }
}
