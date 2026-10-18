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
    }

    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()

    func prepare() {
        rigid.prepare()
        medium.prepare()
        soft.prepare()
        selection.prepare()
    }

    func play(_ moment: Moment) {
        switch moment {
        case .pickUp: medium.impactOccurred(intensity: 0.85)
        case .cardDetent: rigid.impactOccurred(intensity: 0.7)
        case .cardDetentReleased: selection.selectionChanged()
        case .landed: soft.impactOccurred(intensity: 0.75)
        case .splitTarget: rigid.impactOccurred(intensity: 0.9)
        case .splitCommit: medium.impactOccurred(intensity: 1)
        case .control: rigid.impactOccurred(intensity: 0.6)
        }
        prepare()
    }
}
