import UIKit

/// System selection and endpoint feedback share the Thinking page's lifetime.
/// The previous continuous hum is retained by the rollback tag and device IPA.
@MainActor
final class ThinkingSelectionHaptics: NSObject {
    private var visible = false
    private let selection = UISelectionFeedbackGenerator()
    private let boundary = UIImpactFeedbackGenerator(style: .soft)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(suspend),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    func prepare() {
        selection.prepare()
        boundary.prepare()
    }

    func activate() {
        visible = true
        prepare()
    }

    func play() {
        guard visible, UIApplication.shared.applicationState == .active else { return }
        selection.selectionChanged()
    }

    func playBoundary() {
        guard visible, UIApplication.shared.applicationState == .active else { return }
        boundary.impactOccurred(intensity: 0.4)
    }

    @objc func suspend() { visible = false }
}
