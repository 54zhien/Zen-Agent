import UIKit

/// System selection feedback follows the Thinking page's lifetime.
/// The previous continuous hum is retained by the rollback tag and device IPA.
@MainActor
final class ThinkingSelectionHaptics: NSObject {
    private var visible = false
    private let selection = UISelectionFeedbackGenerator()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(suspend),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    func prepare() {
        selection.prepare()
    }

    func activate() {
        visible = true
        prepare()
    }

    func play() {
        guard visible, UIApplication.shared.applicationState == .active else { return }
        selection.selectionChanged()
    }

    @objc func suspend() { visible = false }
}
