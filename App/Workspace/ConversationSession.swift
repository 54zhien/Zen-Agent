import Foundation

/// Warm state survives display eviction without retaining a Timeline or native editor.
@MainActor
final class ConversationSession {
    let conversationID: String
    let composer: ComposerController
    let readingPosition: ReadingPositionController
    private var submissionCoordinator: ComposerSendCoordinator?

    var protectedFileAssetIDs: Set<String> {
        Set(composer.draft.attachments.map(\.id))
            .union(submissionCoordinator?.pendingFileAssetIDs ?? [])
    }

    init(conversationID: String, configuration: ConversationComposerConfiguration?,
         sendAvailability: ComposerSendAvailability? = nil, tolerance: Double = 12) {
        self.conversationID = conversationID
        composer = ComposerController(configuration: configuration, sendAvailability: sendAvailability)
        readingPosition = ReadingPositionController(tolerance: tolerance)
    }
    // A submission outlives its native editor. Its bridge retains Runtime wiring,
    // never the Full Pane or its native view graph.
    func sendCoordinator(bridge: ComposerRuntimeActionBridge, maxProviderSteps: Int) -> ComposerSendCoordinator {
        if let submissionCoordinator { return submissionCoordinator }
        let coordinator = ComposerSendCoordinator(conversationID: conversationID, controller: composer,
            configuration: composer.configuration, bridge: bridge, maxProviderSteps: maxProviderSteps)
        submissionCoordinator = coordinator
        return coordinator
    }

    func canReconstruct(configuration: ConversationComposerConfiguration?) -> Bool {
        let emptyDraft = ComposerDraftState(text: "", selection: ComposerSelection(range: 0..<0),
            references: [], attachments: [], presentationState: .resting)
        return (submissionCoordinator?.submission ?? .idle) == .idle
            && composer.draft == emptyDraft
            && composer.configuration == configuration
            && !composer.isComposing && !composer.isSelectionHandleDragging
            && composer.quoteDragPhase == .idle && composer.pendingExitIntent == nil
            && readingPosition.mode == .followingBottom
    }
}
