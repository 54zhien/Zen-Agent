import UIKit

@MainActor
final class ComposerMotionController {
    enum Phase: Equatable {
        case resting
        case expanding
        case editing
        case collapsing
    }

    private(set) var phase: Phase = .resting
    private(set) var generation = 0
    private(set) var target: ComposerPresentationState = .resting

    func reset(to state: ComposerPresentationState) {
        generation += 1
        target = state
        phase = state == .editing ? .editing : .resting
    }

    @discardableResult
    func begin(_ newTarget: ComposerPresentationState) -> Int {
        generation += 1
        target = newTarget
        phase = newTarget == .editing ? .expanding : .collapsing
        return generation
    }

    @discardableResult
    func settle(_ expectedGeneration: Int, target expectedTarget: ComposerPresentationState,
                finished: Bool) -> Bool {
        guard finished, generation == expectedGeneration, target == expectedTarget else { return false }
        phase = expectedTarget == .editing ? .editing : .resting
        return true
    }

    var keepsEditingLayout: Bool { phase == .expanding || phase == .editing || phase == .collapsing }
}
