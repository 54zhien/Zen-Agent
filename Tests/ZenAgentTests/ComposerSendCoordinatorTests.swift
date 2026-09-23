import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer send coordinator")
@MainActor
struct ComposerSendCoordinatorTests {
    @Test("duplicateTapCreatesOnePendingCommand")
    func duplicateTapCreatesOnePendingCommand() {
        let (controller, coordinator) = makeCoordinator(text: "hello")
        let first = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-first"
        )
        let second = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-second"
        )

        #expect(first?.submissionID == "submission-first")
        #expect(second == nil)
        #expect(coordinator.submission == .awaitingAcceptance(submissionID: "submission-first"))
        #expect(controller.draft.text == "hello")
    }

    @Test("rejectionReenablesSendAndPreservesDraft")
    func rejectionReenablesSendAndPreservesDraft() {
        let (controller, coordinator) = makeCoordinator(text: "keep this")
        let command = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-rejected"
        )
        #expect(command != nil)

        coordinator.rejectSend(submissionID: "submission-rejected")
        #expect(coordinator.submission == .idle)
        #expect(controller.draft.text == "keep this")
        #expect(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-retry"
        ) != nil)
    }

    @Test("acceptanceClearsUneditedSubmission")
    func acceptanceClearsUneditedSubmission() {
        let (controller, coordinator) = makeCoordinator(text: "sent text")
        let command = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-accepted"
        )
        #expect(command != nil)

        let projection = RunProjection(runID: "accepted-run", state: .preparing)
        coordinator.acceptSend(submissionID: "submission-accepted", projection: projection)
        #expect(controller.draft.text.isEmpty)
        #expect(coordinator.submission == .acceptedAwaitingProjection(runID: "accepted-run"))

        coordinator.updateRunProjection(projection)
        #expect(coordinator.submission == .idle)
    }

    @Test("acceptancePreservesEditsMadeWhilePending")
    func acceptancePreservesEditsMadeWhilePending() {
        let (controller, coordinator) = makeCoordinator(text: "first text")
        let command = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "submission-edited"
        )
        #expect(command != nil)
        controller.draft.text = "new edit during request"

        let projection = RunProjection(runID: "edited-run", state: .preparing)
        coordinator.acceptSend(submissionID: "submission-edited", projection: projection)
        #expect(controller.draft.text == "new edit during request")

        coordinator.updateRunProjection(projection)
        #expect(coordinator.submission == .idle)
    }

    private func makeCoordinator(text: String) -> (ComposerController, ComposerSendCoordinator) {
        let providerInstanceID = ProviderInstanceID(rawValue: "composer-test-instance")
        let modelID = ModelID(rawValue: "composer-test-model")
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: providerInstanceID,
            displayName: "Composer Test Model",
            capabilities: [.text, .streaming]
        )
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in "accepted-run" },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in RunProjection(runID: "accepted-run", state: .preparing) },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: providerInstanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: text,
                selection: ComposerSelection(range: 0..<text.count),
                quoteReference: nil,
                attachments: [],
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "composer-test-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )
        return (controller, coordinator)
    }
}
