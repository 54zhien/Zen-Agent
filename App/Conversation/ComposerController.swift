import Foundation
import Observation

/// Draft 的运行时所有者。
@Observable
final class ComposerController {
    var draft: ComposerDraftState
    var configuration: ConversationComposerConfiguration
    private(set) var collapseProgress = ComposerCollapseProgress.expanded
    private(set) var isComposing = false
    private(set) var pendingExitIntent: ComposerPendingExitIntent?

    init(
        draft: ComposerDraftState = ComposerDraftState(
            text: "",
            selection: ComposerSelection(range: 0..<0),
            quoteReference: nil,
            attachments: [],
            presentationState: .resting
        ),
        configuration: ConversationComposerConfiguration
    ) {
        self.draft = draft
        self.configuration = configuration
    }

    @discardableResult
    func handle(_ event: ComposerPresentationEvent) -> ComposerTransition {
        let transition = ComposerPresentationReducer.reduce(
            current: draft.presentationState,
            event: event,
            isComposing: isComposing,
            collapseProgress: collapseProgress,
            pendingExit: pendingExitIntent
        )
        apply(transition)
        return transition
    }

    @discardableResult
    func updateCollapseProgress(_ progress: ComposerCollapseProgress) -> ComposerTransition {
        collapseProgress = progress
        return handle(.timelineCollapseProgressChanged)
    }

    @discardableResult
    func updateComposition(isComposing newValue: Bool) -> ComposerTransition? {
        guard isComposing != newValue else { return nil }
        isComposing = newValue
        guard !newValue else { return nil }

        let transition = ComposerPresentationReducer.reduce(
            current: draft.presentationState,
            event: .compositionEnded,
            isComposing: false,
            collapseProgress: collapseProgress,
            pendingExit: pendingExitIntent
        )
        apply(transition)
        return transition
    }

    private func apply(_ transition: ComposerTransition) {
        draft.presentationState = transition.targetState
        pendingExitIntent = transition.pendingExit
    }
}
