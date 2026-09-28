import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer send coordinator")
@MainActor
struct ComposerSendCoordinatorTests {
    @Test("an active Run can Stop after send configuration disappears")
    func stopWorksWithoutSendConfiguration() async {
        let stopped = StopCallLedger()
        let controller = ComposerController(configuration: nil)
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in "unexpected-start" },
            stop: { runID in await stopped.record(runID) },
            models: { _ in [] },
            projection: { _ in RunProjection(runID: "active-run", state: .cancelled) },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "offline-stop-conversation",
            controller: controller,
            configuration: nil,
            bridge: bridge,
            maxProviderSteps: 4
        )
        coordinator.updateRunProjection(RunProjection(runID: "active-run", state: .streaming))

        _ = await coordinator.handlePrimaryAction()

        #expect(await stopped.runIDs() == ["active-run"])
        #expect(coordinator.sendErrorMessage == nil)
    }

    @Test("a late model lookup cannot send through an old configuration")
    func staleModelLookupCannotSend() async {
        let gate = PendingModelLookup()
        let starts = StopCallLedger()
        let old = ConversationComposerConfiguration(
            providerInstanceID: ProviderInstanceID(rawValue: "old-instance"),
            modelID: ModelID(rawValue: "old-model")
        )
        let new = ConversationComposerConfiguration(
            providerInstanceID: ProviderInstanceID(rawValue: "new-instance"),
            modelID: ModelID(rawValue: "new-model")
        )
        let controller = ComposerController(configuration: old)
        controller.draft.text = "draft stays"
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in
                await starts.record("unexpected")
                return "unexpected-run"
            },
            stop: { _ in },
            models: { _ in await gate.models() },
            projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "switch-conversation",
            controller: controller,
            configuration: old,
            bridge: bridge,
            maxProviderSteps: 4
        )
        let action = Task { await coordinator.handlePrimaryAction() }
        await gate.waitUntilRequested()
        controller.configuration = new
        await gate.release([ModelDescriptor(
            id: old.modelID,
            providerInstanceID: old.providerInstanceID,
            displayName: "Old model",
            capabilities: [.text, .streaming]
        )])
        _ = await action.value

        #expect((await starts.runIDs()).isEmpty)
        #expect(controller.configuration == new)
        #expect(controller.draft.text == "draft stays")
        #expect(coordinator.sendErrorMessage == "模型配置已变更，请重试。")
    }

    @Test("a failed Stop stays visible and leaves the active Run projection intact")
    func failedStopShowsControlledError() async {
        let instanceID = ProviderInstanceID(rawValue: "stop-error-instance")
        let modelID = ModelID(rawValue: "stop-error-model")
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        )
        let controller = ComposerController(configuration: configuration)
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in "unused" },
            stop: { runID in throw AgentRuntimeError.runIsNotActive(runID) },
            models: { _ in [] },
            projection: { _ in RunProjection(runID: "active-run", state: .streaming) },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "stop-error-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )
        coordinator.updateRunProjection(RunProjection(runID: "active-run", state: .streaming))

        let action = await coordinator.handlePrimaryAction()

        #expect(coordinator.sendErrorMessage == "停止失败，请重试。")
        #expect(action == .stop(runID: "active-run", enabled: true))
    }

    @Test("a completed first send leaves the same composer ready for a second send")
    func completedRunAllowsSecondSend() async {
        let ledger = TwoSendLedger()
        let instanceID = ProviderInstanceID(rawValue: "two-send-instance")
        let modelID = ModelID(rawValue: "two-send-model")
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: instanceID,
            displayName: "Two Send Model",
            capabilities: [.text, .streaming]
        )
        let controller = ComposerController(configuration: ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        ))
        let bridge = ComposerRuntimeActionBridge(
            start: { command in await ledger.start(text: command.text) },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in await ledger.projection() },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "two-send-conversation",
            controller: controller,
            configuration: controller.configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )

        controller.draft.text = "first"
        _ = await coordinator.handlePrimaryAction()
        #expect(controller.draft.text.isEmpty)
        #expect(coordinator.submission == .idle)

        let completed = await ledger.completeCurrentRun()
        coordinator.updateRunProjection(completed)
        controller.draft.text = "second"
        _ = await coordinator.handlePrimaryAction()

        #expect(await ledger.texts() == ["first", "second"])
        #expect(controller.draft.text.isEmpty)
        #expect(coordinator.submission == .idle)
    }

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

    @Test("quoteOnlySendIsAcceptedAndClearsOnlyCapturedReferences")
    func quoteOnlySendIsAcceptedAndClearsOnlyCapturedReferences() {
        let captured = makeQuote(id: "captured", snapshot: "quoted passage")
        let newlyAdded = makeQuote(id: "new", snapshot: "new passage")
        let (controller, coordinator) = makeCoordinator(text: "", references: [captured])
        let command = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "quote-only-accepted"
        )
        #expect(command?.references == [captured])
        controller.draft.references.append(newlyAdded)

        coordinator.acceptSend(
            submissionID: "quote-only-accepted",
            projection: RunProjection(runID: "quote-run", state: .preparing)
        )

        #expect(controller.draft.text.isEmpty)
        #expect(controller.draft.references == [newlyAdded])
    }

    @Test("quoteSendFailureRetainsDraftReferences")
    func quoteSendFailureRetainsDraftReferences() {
        let captured = makeQuote(id: "captured", snapshot: "quoted passage")
        let (controller, coordinator) = makeCoordinator(text: "", references: [captured])
        #expect(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "quote-send-failure"
        ) != nil)

        coordinator.rejectSend(submissionID: "quote-send-failure")
        #expect(coordinator.submission == .idle)
        #expect(controller.draft.references == [captured])
        #expect(controller.draft.text.isEmpty)
    }

    @Test("quoteEditDuringInFlightAcceptanceKeepsNewReferences")
    func quoteEditDuringInFlightAcceptanceKeepsNewReferences() {
        let captured = makeQuote(id: "captured", snapshot: "quoted passage")
        let newlyAdded = makeQuote(id: "new", snapshot: "new passage")
        let (controller, coordinator) = makeCoordinator(text: "original", references: [captured])
        #expect(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "quote-edit-in-flight"
        ) != nil)
        controller.draft.text = "edited while sending"
        controller.draft.references.append(newlyAdded)

        coordinator.acceptSend(
            submissionID: "quote-edit-in-flight",
            projection: RunProjection(runID: "quote-edit-run", state: .preparing)
        )

        #expect(controller.draft.text == "edited while sending")
        #expect(controller.draft.references == [newlyAdded])
    }

    private func makeCoordinator(
        text: String,
        references: [QuoteReference] = []
    ) -> (ComposerController, ComposerSendCoordinator) {
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
                references: references,
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

    private func makeQuote(id: String, snapshot: String) -> QuoteReference {
        QuoteReference(
            id: id,
            source: QuoteSourceLocator(
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: "source-part-\(id)",
                range: QuoteTextRange(utf16Start: 0, utf16Length: snapshot.utf16.count)
            ),
            snapshot: snapshot,
            createdAt: Fixtures.epoch
        )
    }
}

private actor StopCallLedger {
    private var values: [String] = []

    func record(_ runID: String) { values.append(runID) }
    func runIDs() -> [String] { values }
}

private actor PendingModelLookup {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter: CheckedContinuation<[ModelDescriptor], Never>?

    func models() async -> [ModelDescriptor] {
        await withCheckedContinuation { continuation in
            resultWaiter = continuation
            requested = true
            let waiters = requestWaiters
            requestWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func release(_ descriptors: [ModelDescriptor]) {
        resultWaiter?.resume(returning: descriptors)
        resultWaiter = nil
    }
}

private actor TwoSendLedger {
    private var sentTexts: [String] = []
    private var currentProjection: RunProjection?

    func start(text: String) -> String {
        sentTexts.append(text)
        let runID = "run-\(sentTexts.count)"
        currentProjection = RunProjection(runID: runID, state: .preparing)
        return runID
    }

    func projection() -> RunProjection? { currentProjection }

    func completeCurrentRun() -> RunProjection {
        let completed = RunProjection(runID: currentProjection!.runID, state: .completed)
        currentProjection = completed
        return completed
    }

    func texts() -> [String] { sentTexts }
}
