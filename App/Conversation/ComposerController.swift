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
    private(set) var quoteDragPhase = ComposerQuoteDragPhase.idle
    private(set) var isSelectionHandleDragging = false

    private var temporaryQuoteDropExpansion = false
    private var committedQuoteDropExpansion = false

    var effectiveCollapseProgress: ComposerCollapseProgress {
        temporaryQuoteDropExpansion || committedQuoteDropExpansion
            ? .expanded
            : collapseProgress
    }

    init(
        draft: ComposerDraftState = ComposerDraftState(
            text: "",
            selection: ComposerSelection(range: 0..<0),
            references: [],
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
        switch event {
        case .quoteDragPhaseChanged(let phase):
            let previous = quoteDragPhase
            quoteDragPhase = phase
            if phase == .overDropZone, draft.presentationState == .compact {
                temporaryQuoteDropExpansion = true
            } else if phase == .idle,
                      previous != .idle,
                      temporaryQuoteDropExpansion,
                      !committedQuoteDropExpansion {
                temporaryQuoteDropExpansion = false
                let restored = ComposerPresentationReducer.reduce(
                    current: draft.presentationState,
                    event: .timelineCollapseProgressChanged,
                    isComposing: isComposing,
                    collapseProgress: collapseProgress,
                    pendingExit: pendingExitIntent
                )
                apply(restored)
                return restored
            }
        case .selectionHandleDragChanged(let isDragging):
            isSelectionHandleDragging = isDragging
        case .quoteDropCommitted:
            temporaryQuoteDropExpansion = false
            committedQuoteDropExpansion = true
        case .textAreaTapped,
             .conversationBackgroundTapped,
             .keyboardDismissed,
             .timelineCollapseProgressChanged,
             .compactTapped,
             .compositionEnded:
            break
        }

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
        if collapseProgress != progress {
            temporaryQuoteDropExpansion = false
            committedQuoteDropExpansion = false
        }
        collapseProgress = progress
        return handle(.timelineCollapseProgressChanged)
    }

    func canBeginSurfaceLift(keyboardVisible: Bool, stableBottomAnchor: Bool) -> Bool {
        quoteDragPhase == .idle
            && !isSelectionHandleDragging
            && !keyboardVisible
            && stableBottomAnchor
            && draft.presentationState != .editing
    }

    @discardableResult
    func addQuoteReference(_ reference: QuoteReference) -> Bool {
        guard !draft.references.contains(where: { $0.source == reference.source }) else {
            return false
        }
        draft.references.append(reference)
        _ = handle(.quoteDropCommitted)
        return true
    }

    func removeQuoteReference(id: String) {
        draft.references.removeAll { $0.id == id }
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
