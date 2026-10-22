import UIKit

/// The single vocabulary of Workspace touch feedback.
///
/// Every Surface gesture names a moment here instead of building its own
/// generator, so pick-up, detents and landings keep one consistent weight.
/// Intensities are device-calibration starting points, not measured values.
@MainActor
final class WorkspaceHaptics {
    static let shared = WorkspaceHaptics()

    enum Moment {
        /// The finger has picked the Surface up.
        case pickUp
        /// Lift crossed the point where release commits to a Card.
        case cardDetent
        /// Lift fell back below that point; release would return to Full.
        case cardDetentReleased
        /// A Card or Full settlement reached its resting geometry.
        case landed
        /// The lifted Surface snapped into a Split half.
        case splitTarget
        /// Release committed the Split.
        case splitCommit
        /// A Composer control (More, Send, Stop) was pressed.
        case control
        /// A system tick when the Thinking selection changes.
        case thinkingDetent
        /// A soft impact when the finger crosses beyond either Thinking endpoint.
        case thinkingBoundary
    }

    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let thinking = ThinkingSelectionHaptics()

    func prepare() {
        rigid.prepare()
        medium.prepare()
        heavy.prepare()
        thinking.prepare()
    }

    func prepareThinking() { thinking.activate() }

    func stopThinking() { thinking.suspend() }

    func play(_ moment: Moment) {
        switch moment {
        case .pickUp: heavy.impactOccurred(intensity: 1)
        case .cardDetent: rigid.impactOccurred(intensity: 1)
        case .cardDetentReleased: medium.impactOccurred(intensity: 0.85)
        case .landed: medium.impactOccurred(intensity: 1)
        case .splitTarget: rigid.impactOccurred(intensity: 1)
        case .splitCommit: heavy.impactOccurred(intensity: 1)
        case .control: rigid.impactOccurred(intensity: 1)
        case .thinkingDetent: thinking.play()
        case .thinkingBoundary: thinking.playBoundary()
        }
        prepare()
    }
}
