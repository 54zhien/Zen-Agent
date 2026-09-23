import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer presentation reducer")
struct ComposerPresentationReducerTests {
    @Test("restingTextTapEntersEditing")
    func restingTextTapEntersEditing() {
        let transition = reduce(current: .resting, event: .textAreaTapped)

        #expect(transition.targetState == .editing)
        #expect(transition.focusCommand == .requestFocus)
        #expect(transition.pendingExit == nil)
    }

    @Test("compactTapEntersEditingWithoutIntermediateResting")
    func compactTapEntersEditingWithoutIntermediateResting() {
        let transition = reduce(current: .compact, event: .compactTapped)

        #expect(transition.targetState == .editing)
        #expect(transition.targetState != .resting)
        #expect(transition.focusCommand == .requestFocus)
    }

    @Test("outsideTapAndKeyboardDismissReturnToResting")
    func outsideTapAndKeyboardDismissReturnToResting() {
        let outsideTap = reduce(current: .editing, event: .conversationBackgroundTapped)
        let keyboardDismiss = reduce(current: .editing, event: .keyboardDismissed)

        #expect(outsideTap.targetState == .resting)
        #expect(outsideTap.focusCommand == .requestResign)
        #expect(keyboardDismiss.targetState == .resting)
        #expect(keyboardDismiss.focusCommand == .none)
    }

    @Test("collapseUsesHysteresisOutsideEditing")
    func collapseUsesHysteresisOutsideEditing() {
        let belowEnter = reduce(
            current: .resting,
            event: .timelineCollapseProgressChanged,
            progress: 0.71
        )
        let entersCompact = reduce(
            current: .resting,
            event: .timelineCollapseProgressChanged,
            progress: ComposerPresentationReducer.compactEnterThreshold
        )
        let middleFromCompact = reduce(
            current: .compact,
            event: .timelineCollapseProgressChanged,
            progress: 0.64
        )
        let exitsAtThreshold = reduce(
            current: .compact,
            event: .timelineCollapseProgressChanged,
            progress: ComposerPresentationReducer.compactExitThreshold
        )
        let middleFromResting = reduce(
            current: .resting,
            event: .timelineCollapseProgressChanged,
            progress: 0.64
        )
        let quoteDropFromCompact = reduce(
            current: .compact,
            event: .quoteDragPhaseChanged(.overDropZone),
            progress: 1
        )

        #expect(ComposerPresentationReducer.compactExitThreshold < ComposerPresentationReducer.compactEnterThreshold)
        #expect(belowEnter.targetState == .resting)
        #expect(entersCompact.targetState == .compact)
        #expect(middleFromCompact.targetState == .compact)
        #expect(exitsAtThreshold.targetState == .resting)
        #expect(middleFromResting.targetState == .resting)
        #expect(quoteDropFromCompact.targetState == .resting)
        #expect(quoteDropFromCompact.focusCommand == .none)
    }

    @Test("scrollNeverCompactsActiveEditing")
    func scrollNeverCompactsActiveEditing() {
        let transition = reduce(
            current: .editing,
            event: .timelineCollapseProgressChanged,
            progress: 1
        )

        #expect(transition.targetState == .editing)
        #expect(transition.focusCommand == .none)
    }

    @Test("compositionVetoesEveryExitAndResign")
    func compositionVetoesEveryExitAndResign() {
        let outsideTap = reduce(
            current: .editing,
            event: .conversationBackgroundTapped,
            isComposing: true
        )
        let keyboardDismiss = reduce(
            current: .editing,
            event: .keyboardDismissed,
            isComposing: true
        )
        let timelineCollapse = reduce(
            current: .editing,
            event: .timelineCollapseProgressChanged,
            isComposing: true,
            progress: 1
        )

        #expect(outsideTap.targetState == .editing)
        #expect(outsideTap.focusCommand == .none)
        #expect(outsideTap.pendingExit == .conversationBackgroundTap)
        #expect(keyboardDismiss.targetState == .editing)
        #expect(keyboardDismiss.focusCommand == .none)
        #expect(keyboardDismiss.pendingExit == .keyboardDismissed)
        #expect(timelineCollapse.targetState == .editing)
        #expect(timelineCollapse.focusCommand == .none)
        #expect(timelineCollapse.pendingExit == nil)
    }

    @Test("compositionEndAppliesDeferredExitOnce")
    func compositionEndAppliesDeferredExitOnce() {
        let outsideTap = reduce(
            current: .editing,
            event: .conversationBackgroundTapped,
            isComposing: true
        )
        let deferredOutsideTap = reduce(
            current: .editing,
            event: .compositionEnded,
            pendingExit: outsideTap.pendingExit
        )
        let repeatedOutsideTap = reduce(
            current: deferredOutsideTap.targetState,
            event: .compositionEnded,
            pendingExit: deferredOutsideTap.pendingExit
        )

        let keyboardDismiss = reduce(
            current: .editing,
            event: .keyboardDismissed,
            isComposing: true
        )
        let deferredKeyboardDismiss = reduce(
            current: .editing,
            event: .compositionEnded,
            pendingExit: keyboardDismiss.pendingExit
        )
        let compositionWithoutExit = reduce(
            current: .editing,
            event: .compositionEnded
        )

        #expect(deferredOutsideTap.targetState == .resting)
        #expect(deferredOutsideTap.pendingExit == nil)
        #expect(deferredOutsideTap.focusCommand == .requestResign)
        #expect(repeatedOutsideTap.focusCommand == .none)
        #expect(deferredKeyboardDismiss.targetState == .resting)
        #expect(deferredKeyboardDismiss.pendingExit == nil)
        #expect(deferredKeyboardDismiss.focusCommand == .none)
        #expect(compositionWithoutExit.targetState == .editing)
        #expect(compositionWithoutExit.focusCommand == .none)

        let controller = ComposerController(
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "composer-test-instance"),
                modelID: ModelID(rawValue: "composer-test-model")
            )
        )
        controller.draft.presentationState = .editing
        controller.updateComposition(isComposing: true)
        controller.handle(.conversationBackgroundTapped)
        let controllerEnd = controller.updateComposition(isComposing: false)
        let repeatedControllerEnd = controller.updateComposition(isComposing: false)

        #expect(controllerEnd?.targetState == .resting)
        #expect(controllerEnd?.focusCommand == .requestResign)
        #expect(controller.pendingExitIntent == nil)
        #expect(repeatedControllerEnd == nil)
    }

    private func reduce(
        current: ComposerPresentationState,
        event: ComposerPresentationEvent,
        isComposing: Bool = false,
        progress: Double = 0,
        pendingExit: ComposerPendingExitIntent? = nil
    ) -> ComposerTransition {
        ComposerPresentationReducer.reduce(
            current: current,
            event: event,
            isComposing: isComposing,
            collapseProgress: ComposerCollapseProgress(value: progress)!,
            pendingExit: pendingExit
        )
    }
}
