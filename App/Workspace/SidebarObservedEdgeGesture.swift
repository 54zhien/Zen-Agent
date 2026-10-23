#if DEBUG
import UIKit

/// Temporary observation of native recognition. Every UIKit decision and touch
/// delivery goes through super unchanged; the observer never drives navigation.
@MainActor
final class SidebarObservedEdgeGesture: UIScreenEdgePanGestureRecognizer {
    var observe: ((String) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        observe?("native began state=\(state.rawValue),recognizer=\(self)")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        observe?("native ending state=\(state.rawValue),translation=\(translation(in: view?.window)),recognizer=\(self)")
        super.touchesEnded(touches, with: event)
        observe?("native ended state=\(state.rawValue),recognizer=\(self)")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        observe?("native cancelled state=\(state.rawValue),recognizer=\(self)")
        super.touchesCancelled(touches, with: event)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        let result = super.canBePrevented(by: preventingGestureRecognizer)
        observe?("native canBePrevented=\(result),by=\(preventingGestureRecognizer)")
        return result
    }

    override func reset() {
        observe?("native reset state=\(state.rawValue),recognizer=\(self)")
        super.reset()
    }
}
#endif
