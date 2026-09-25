import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("W1 send confirmation")
@MainActor
struct W1SendConfirmationTests {
    @Test("primaryActionRetainsAndRetriesConfirmationWithoutRestarting")
    func primaryActionRetainsAndRetriesConfirmationWithoutRestarting() async throws {
        let fixture = try makeFixture(steps: [.inconclusive, .read])
        defer { fixture.cleanup() }

        let pane = try #require(fixture.model.pane)
        let coordinator = try #require(fixture.model.composerSendCoordinator)
        pane.composer.draft.text = "retain the primary action submission"

        let action = await coordinator.handlePrimaryAction()
        #expect(action == .send(enabled: false))

        let handle = try #require(coordinator.confirmationHandle)
        let command = handle.command
        #expect(command.text == "retain the primary action submission")
        #expect(!handle.runtimeStartFailed)
        #expect(handle.runtimeStartReturnedRunID != nil)
        #expect(coordinator.pendingCommand == command)
        #expect(coordinator.submission == .awaitingAcceptance(
            submissionID: command.submissionID
        ))
        #expect(fixture.model.blocksConversationReplacement)
        try assertSingleCommittedTurn(command, in: fixture)

        let (callsAfterStart, readsAfterStart, commandsAfterStart) = await fixture.readPlan.snapshot()
        #expect(callsAfterStart == 1)
        #expect(readsAfterStart == 0)
        #expect(commandsAfterStart == [command])

        let duplicateAction = await coordinator.handlePrimaryAction()
        #expect(duplicateAction == .send(enabled: false))
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.pendingCommand == command)
        let (callsAfterDuplicate, _, commandsAfterDuplicate) = await fixture.readPlan.snapshot()
        #expect(callsAfterDuplicate == callsAfterStart)
        #expect(commandsAfterDuplicate == [command])
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle == nil)
        #expect(coordinator.pendingCommand == nil)
        #expect(!fixture.model.blocksConversationReplacement)
        let (callsAfterRetry, readsAfterRetry, commandsAfterRetry) = await fixture.readPlan.snapshot()
        #expect(callsAfterRetry == 2)
        #expect(readsAfterRetry == 1)
        #expect(commandsAfterRetry == [command, command])
        try assertSingleCommittedTurn(command, in: fixture)
        try await fixture.runtime.waitForCompletion(
            runID: try #require(handle.runtimeStartReturnedRunID)
        )
    }

    @Test("postCommitReadFailureRetainsOriginalSubmissionAndRootCoordinator")
    func postCommitReadFailureRetainsOriginalSubmissionAndRootCoordinator() async throws {
        let fixture = try makeFixture(steps: [.inconclusive, .inconclusive, .read])
        defer { fixture.cleanup() }

        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let coordinator = try #require(fixture.model.composerSendCoordinator)
        let originalTarget = try #require(fixture.model.target)
        let originalQuote = quote(id: "captured-quote", snapshot: "captured quote")
        let originalAttachment = try makeAttachment(in: fixture, name: "captured.pdf")
        pane.composer.draft.text = "original submitted text"
        pane.composer.draft.references = [originalQuote]
        pane.composer.draft.attachments = [originalAttachment]

        let command = try #require(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: true,
            fileInputReady: true,
            submissionID: "w1-confirm-original-submission"
        ))
        #expect(coordinator.pendingCommand == command)
        #expect(command.text == "original submitted text")
        #expect(command.references == [originalQuote])
        #expect(command.attachments == [sendAttachment(for: originalAttachment)])

        let handle = try await requireConfirmation(from: bridge, for: command)
        #expect(coordinator.retainPendingConfirmation(handle))
        #expect(handle.command == command)
        #expect(handle.runtimeStartReturnedRunID != nil)
        #expect(!handle.runtimeStartFailed)
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.submission == .awaitingAcceptance(
            submissionID: command.submissionID
        ))
        #expect(fixture.model.blocksConversationReplacement)
        #expect(fixture.model.canPresentCurrentPane)
        try assertSingleCommittedTurn(command, in: fixture)

        let (callsAfterStart, readsAfterStart, _) = await fixture.readPlan.snapshot()
        #expect(callsAfterStart == 1)
        #expect(readsAfterStart == 0)

        let duplicateAction = await coordinator.handlePrimaryAction()
        #expect(duplicateAction == .send(enabled: false))
        #expect(coordinator.pendingCommand == command)
        #expect(coordinator.confirmationHandle === handle)
        let (callsAfterDuplicate, _, _) = await fixture.readPlan.snapshot()
        #expect(callsAfterDuplicate == callsAfterStart)
        try assertSingleCommittedTurn(command, in: fixture)

        let changedQuote = quote(id: originalQuote.id, snapshot: "edited quote")
        let addedQuote = quote(id: "added-quote", snapshot: "new quote")
        let changedAttachment = AttachmentReference(
            id: originalAttachment.id,
            versionID: "edited-version",
            fingerprint: "sha256:edited",
            displayName: "edited.pdf",
            kind: .file
        )
        let addedAttachment = AttachmentReference(
            id: "added-asset",
            versionID: "added-version",
            fingerprint: "sha256:added",
            displayName: "added.pdf",
            kind: .file
        )
        pane.composer.draft.text = "original submitted text plus an edit"
        pane.composer.draft.references = [changedQuote, addedQuote]
        pane.composer.draft.attachments = [changedAttachment, addedAttachment]

        let setup = try #require(fixture.model.providerSetup)
        setup.startNewAttempt()
        setup.apiKey = "w1-confirm-new-key-\(UUID().uuidString)"
        #expect(setup.save())
        let replacementTarget = try #require(fixture.model.target)
        #expect(replacementTarget.providerInstanceID == setup.instanceID)
        #expect(replacementTarget != originalTarget)
        #expect(fixture.model.pane === pane)
        #expect(fixture.model.composerSendCoordinator === coordinator)
        #expect(coordinator.pendingCommand == command)
        #expect(coordinator.confirmationHandle === handle)
        #expect(handle.command == command)
        #expect(command.providerInstanceID == originalTarget.providerInstanceID)
        #expect(pane.composer.configuration.providerInstanceID == replacementTarget.providerInstanceID)

        let originalConversationID = fixture.model.conversationID
        let originalRouter = fixture.model.router
        let canSwitch = fixture.model.openConversation(id: originalConversationID)
        #expect(!canSwitch)
        fixture.model.newConversation()
        fixture.model.assemble()
        #expect(fixture.model.conversationID == originalConversationID)
        #expect(fixture.model.pane === pane)
        #expect(fixture.model.actionBridge != nil)
        #expect(fixture.model.composerSendCoordinator === coordinator)
        #expect(fixture.model.router === originalRouter)
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.pendingCommand == command)

        let rebuiltPaneView = ConversationPaneView(
            pane: pane,
            runtime: fixture.runtime,
            actionBridge: bridge,
            sendCoordinator: coordinator,
            maxProviderSteps: AppShellModel.maxProviderSteps
        )
        let rebuiltComposerView = ConversationComposerView(
            conversationID: originalConversationID,
            controller: pane.composer,
            bridge: bridge,
            coordinator: coordinator,
            maxProviderSteps: AppShellModel.maxProviderSteps
        )
        #expect(rebuiltPaneView.sendCoordinator === coordinator)
        #expect(rebuiltComposerView.coordinator === coordinator)

        let storesBeforeReadOnlyRetry = fixture.backend.storeCallCount
        fixture.backend.setLoadUnavailable(true)
        #expect(fixture.model.retryExistingTarget() == "Keychain 不可用")
        #expect(!fixture.model.canSend)
        #expect(fixture.model.canPresentCurrentPane)
        #expect(fixture.model.pane === pane)
        #expect(fixture.model.composerSendCoordinator === coordinator)
        #expect(coordinator.confirmationHandle === handle)
        #expect(fixture.backend.storeCallCount == storesBeforeReadOnlyRetry)
        fixture.backend.setLoadUnavailable(false)
        #expect(fixture.model.retryExistingTarget() == "配置已恢复")
        #expect(fixture.model.canSend)
        #expect(fixture.backend.storeCallCount == storesBeforeReadOnlyRetry)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.pendingCommand == command)
        #expect(coordinator.submission == .awaitingAcceptance(
            submissionID: command.submissionID
        ))
        #expect(pane.composer.draft.text == "original submitted text plus an edit")
        #expect(pane.composer.draft.references == [changedQuote, addedQuote])
        #expect(pane.composer.draft.attachments == [changedAttachment, addedAttachment])
        let (callsAfterFailedRetry, readsAfterFailedRetry, _) = await fixture.readPlan.snapshot()
        #expect(callsAfterFailedRetry == 2)
        #expect(readsAfterFailedRetry == 0)
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle == nil)
        #expect(coordinator.pendingCommand == nil)
        #expect(coordinator.submission == .idle)
        #expect(!fixture.model.blocksConversationReplacement)
        #expect(fixture.model.canSend)
        #expect(fixture.model.target == replacementTarget)
        #expect(pane.composer.draft.text == "original submitted text plus an edit")
        #expect(pane.composer.draft.references == [changedQuote, addedQuote])
        #expect(pane.composer.draft.attachments == [changedAttachment, addedAttachment])
        let (callsAfterRecovery, readsAfterRecovery, _) = await fixture.readPlan.snapshot()
        #expect(callsAfterRecovery == 3)
        #expect(readsAfterRecovery == 1)
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        let (callsAfterExtraTap, _, _) = await fixture.readPlan.snapshot()
        #expect(callsAfterExtraTap == callsAfterRecovery)
        try await fixture.runtime.waitForCompletion(
            runID: try #require(handle.runtimeStartReturnedRunID)
        )
    }

    @Test("returnedRunWithoutConfirmationAndWrongRunIDRemainBlockedUntilReadMatches")
    func returnedRunWithoutConfirmationAndWrongRunIDRemainBlockedUntilReadMatches() async throws {
        let fixture = try makeFixture(steps: [
            .noRun,
            .noRun,
            .matchingRun(runID: "wrong-run-id", state: .completed),
            .read,
        ])
        defer { fixture.cleanup() }

        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let coordinator = try #require(fixture.model.composerSendCoordinator)
        pane.composer.draft.text = "confirm only the returned run"
        let command = try #require(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "w1-confirm-returned-run"
        ))
        let handle = try await requireConfirmation(from: bridge, for: command)
        #expect(handle.runtimeStartReturnedRunID != nil)
        #expect(coordinator.retainPendingConfirmation(handle))
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.pendingCommand == command)
        #expect(fixture.model.blocksConversationReplacement)
        #expect(coordinator.sendErrorMessage == "提交状态尚未确认，请重试确认。")
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle === handle)
        #expect(coordinator.pendingCommand == command)
        #expect(fixture.model.blocksConversationReplacement)
        try assertSingleCommittedTurn(command, in: fixture)

        await coordinator.retryPendingConfirmation()
        #expect(coordinator.confirmationHandle == nil)
        #expect(coordinator.pendingCommand == nil)
        #expect(!fixture.model.blocksConversationReplacement)
        let (calls, reads, _) = await fixture.readPlan.snapshot()
        #expect(calls == 4)
        #expect(reads == 1)
        try assertSingleCommittedTurn(command, in: fixture)
        try await fixture.runtime.waitForCompletion(
            runID: try #require(handle.runtimeStartReturnedRunID)
        )
    }

    @Test("startFailureWithCompleteNoRunRejectsWithoutClearingDraft")
    func startFailureWithCompleteNoRunRejectsWithoutClearingDraft() async throws {
        let fixture = try makeFixture(steps: [.read, .read])
        defer { fixture.cleanup() }

        var hiddenConversation = Fixtures.conversation(id: fixture.model.conversationID)
        hiddenConversation.lifecycle = .pendingDeletion
        let persistedHiddenConversation = hiddenConversation
        try fixture.store.database.write { db in
            try persistedHiddenConversation.insert(db)
        }
        let pane = try #require(fixture.model.pane)
        let coordinator = try #require(fixture.model.composerSendCoordinator)
        pane.composer.draft.text = "keep this draft after precommit failure"

        _ = await coordinator.handlePrimaryAction()

        #expect(coordinator.submission == .idle)
        #expect(coordinator.pendingCommand == nil)
        #expect(coordinator.confirmationHandle == nil)
        #expect(coordinator.sendErrorMessage == "发送失败，请重试。")
        #expect(pane.composer.draft.text == "keep this draft after precommit failure")
        #expect(!fixture.model.blocksConversationReplacement)
        #expect(try fixture.store.messages(inConversation: fixture.model.conversationID).isEmpty)
        #expect(try fixture.store.runs(inConversation: fixture.model.conversationID).isEmpty)

        let (_, readsAfterFirst, firstCommands) = await fixture.readPlan.snapshot()
        #expect(readsAfterFirst == 1)
        #expect(firstCommands.count == 1)

        _ = await coordinator.handlePrimaryAction()
        let (_, readsAfterSecond, secondCommands) = await fixture.readPlan.snapshot()
        #expect(readsAfterSecond == 2)
        #expect(secondCommands.count == 2)
        #expect(secondCommands[0].submissionID != secondCommands[1].submissionID)
        #expect(try fixture.store.messages(inConversation: fixture.model.conversationID).isEmpty)
        #expect(try fixture.store.runs(inConversation: fixture.model.conversationID).isEmpty)
        #expect(pane.composer.draft.text == "keep this draft after precommit failure")
    }

    @Test("confirmationRejectsMismatchedRunConversationTriggerAndPayload")
    func confirmationRejectsMismatchedRunConversationTriggerAndPayload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let coordinator = try #require(fixture.model.composerSendCoordinator)
        let reference = quote(id: "confirmation-payload-quote", snapshot: "expected snapshot")
        let attachment = try makeAttachment(in: fixture, name: "confirmation-payload.txt")
        pane.composer.draft.text = "payload to validate"
        pane.composer.draft.references = [reference]
        pane.composer.draft.attachments = [attachment]
        let command = try #require(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: true,
            submissionID: "w1-confirm-payload-validation"
        ))

        let runID = try await bridge.start(command)
        try await fixture.runtime.waitForCompletion(runID: runID)
        let run = try #require(try fixture.store.run(submissionID: command.submissionID))
        #expect(AppAssembly.confirmSubmission(
            command,
            expectedRunID: runID,
            in: fixture.store
        ) == .matchingRun(runID: runID, state: run.state))

        #expect(AppAssembly.confirmSubmission(
            command,
            expectedRunID: "wrong-run-id",
            in: fixture.store
        ) == .inconclusive)

        var wrongConversation = command
        wrongConversation.conversationID = "another-conversation"
        #expect(AppAssembly.confirmSubmission(
            wrongConversation,
            expectedRunID: runID,
            in: fixture.store
        ) == .inconclusive)

        var wrongText = command
        wrongText.text += " changed"
        #expect(AppAssembly.confirmSubmission(
            wrongText,
            expectedRunID: runID,
            in: fixture.store
        ) == .inconclusive)

        var wrongReference = command
        wrongReference.references[0] = quote(
            id: reference.id,
            snapshot: "different snapshot"
        )
        #expect(AppAssembly.confirmSubmission(
            wrongReference,
            expectedRunID: runID,
            in: fixture.store
        ) == .inconclusive)

        var wrongAttachment = command
        wrongAttachment.attachments[0] = SendAttachment(
            assetID: attachment.id,
            versionID: attachment.versionID,
            fingerprint: "sha256:wrong",
            kind: attachment.kind,
            displayName: attachment.displayName
        )
        #expect(AppAssembly.confirmSubmission(
            wrongAttachment,
            expectedRunID: runID,
            in: fixture.store
        ) == .inconclusive)

        let message = try #require(try fixture.store.messages(
            inConversation: command.conversationID
        ).first(where: { $0.role == .user }))
        try fixture.store.database.write { db in
            try db.execute(
                sql: "UPDATE agentRun SET triggerMessageID = NULL WHERE id = ?",
                arguments: [runID]
            )
        }
        #expect(AppAssembly.confirmSubmission(
            command,
            expectedRunID: runID,
            in: fixture.store
        ) == .inconclusive)
        try fixture.store.database.write { db in
            try db.execute(
                sql: "UPDATE agentRun SET triggerMessageID = ? WHERE id = ?",
                arguments: [message.id, runID]
            )
        }
        #expect(AppAssembly.confirmSubmission(
            command,
            expectedRunID: runID,
            in: fixture.store
        ) == .matchingRun(runID: runID, state: run.state))
    }

    private func makeFixture(
        steps: [W1ConfirmationReadPlan.Step] = []
    ) throws -> W1SendConfirmationFixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenagent-w1-confirm-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            protectionRequirement: .bestEffort
        )
        let backend = W1ConfirmationSecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([])]
        )
        let instanceID = ProviderInstanceID(rawValue: "w1-confirm-instance-\(UUID().uuidString)")
        let reference = CredentialReference(id: "w1-confirm-key-\(UUID().uuidString)")
        try store.createProviderInstance(ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "W1 confirmation test",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        ))
        try credentials.provision(SecretValue("w1-confirm-secret-\(UUID().uuidString)"), as: reference)

        let router = RunEventRouter()
        let runtime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            onEvent: { event in await router.handle(event) },
            toolRegistry: .empty,
            managedFileStore: managedFiles
        )
        let dependencies = AppAssembly.Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let defaultsSuite = "ZenAgentTests.W1SendConfirmation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set(instanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
        defaults.set(Stage2GateFixture.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
        let readPlan = W1ConfirmationReadPlan(steps: steps)
        let interceptor: AppAssembly.ConfirmationReadInterceptor = { command, runID, read in
            await readPlan.intercept(command, returnedRunID: runID, operation: read)
        }
        let model = AppShellModel(
            dependencies: dependencies,
            userDefaults: defaults,
            confirmationReadInterceptor: interceptor
        )
        return W1SendConfirmationFixture(
            store: store,
            managedFiles: managedFiles,
            supportRoot: supportRoot,
            backend: backend,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            dependencies: dependencies,
            defaults: defaults,
            defaultsSuite: defaultsSuite,
            readPlan: readPlan,
            model: model
        )
    }

    private func requireConfirmation(
        from bridge: ComposerRuntimeActionBridge,
        for command: SendCommand
    ) async throws -> ComposerSendConfirmationHandle {
        do {
            _ = try await bridge.start(command)
        } catch let failure as ComposerSendFailure {
            guard case .confirmationRequired(let handle) = failure else { throw failure }
            return handle
        }
        throw W1SendConfirmationTestFailure.expectedConfirmationHandle
    }

    private func assertSingleCommittedTurn(
        _ command: SendCommand,
        in fixture: W1SendConfirmationFixture
    ) throws {
        let conversationCount = try fixture.store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
        }
        #expect(conversationCount == 1)
        let conversation = try #require(try fixture.store.conversation(id: command.conversationID))
        #expect(conversation.id == command.conversationID)

        let messages = try fixture.store.messages(inConversation: command.conversationID)
        let userMessages = messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        let message = try #require(userMessages.first)
        let parts = try fixture.store.parts(ofMessage: message.id)
        #expect(parts.count == 1)
        let part = try #require(parts.first)
        #expect(part.sequence == 0)
        #expect(part.state == .completed)
        #expect(try fixture.store.text(ofPart: part.id) == command.text)

        let savedReferences = try fixture.store.quoteReferences(forMessageID: message.id)
        #expect(savedReferences.count == command.references.count)
        for (sequence, pair) in zip(command.references, savedReferences).enumerated() {
            let (expected, saved) = pair
            #expect(saved.sequence == sequence)
            #expect(saved.id == expected.id)
            #expect(saved.sourceConversationID == expected.source.sourceConversationID)
            #expect(saved.sourceMessageID == expected.source.sourceMessageID)
            #expect(saved.sourcePartID == expected.source.sourcePartID)
            #expect(saved.sourceUTF16Start == expected.source.range.utf16Start)
            #expect(saved.sourceUTF16Length == expected.source.range.utf16Length)
            #expect(saved.snapshot == expected.snapshot)
            #expect(saved.createdAt == expected.createdAt)
        }

        let savedAttachments = try fixture.store.attachments(forMessage: message.id)
        #expect(savedAttachments.count == command.attachments.count)
        for (sequence, pair) in zip(command.attachments, savedAttachments).enumerated() {
            let (expected, saved) = pair
            #expect(saved.sequence == sequence)
            #expect(saved.assetID == expected.assetID)
            #expect(saved.versionID == expected.versionID)
            #expect(try fixture.store.fileAsset(id: saved.assetID)?.displayName
                == expected.displayName)
            #expect(try fixture.store.fileAssetVersion(id: saved.versionID)?.contentFingerprint
                == expected.fingerprint)
        }

        let parentRuns = try fixture.store.runs(inConversation: command.conversationID)
            .filter { $0.kind == .parent }
        #expect(parentRuns.count == 1)
        let run = try #require(parentRuns.first)
        #expect(run.submissionID == command.submissionID)
        #expect(run.conversationID == command.conversationID)
        #expect(run.parentRunID == nil)
        #expect(run.triggerMessageID == message.id)
    }

    private func makeAttachment(
        in fixture: W1SendConfirmationFixture,
        name: String
    ) throws -> AttachmentReference {
        let descriptor = try fixture.managedFiles.ingest(
            data: Data("attachment bytes for \(name)".utf8),
            displayName: name,
            mediaType: "text/plain",
            in: fixture.store
        )
        return AttachmentReference(
            id: descriptor.assetID,
            versionID: descriptor.versionID,
            fingerprint: descriptor.fingerprint,
            displayName: descriptor.displayName,
            kind: .file
        )
    }

    private func sendAttachment(for reference: AttachmentReference) -> SendAttachment {
        SendAttachment(
            assetID: reference.id,
            versionID: reference.versionID,
            fingerprint: reference.fingerprint,
            kind: reference.kind,
            displayName: reference.displayName
        )
    }

    private func quote(id: String, snapshot: String) -> QuoteReference {
        QuoteReference(
            id: id,
            source: QuoteSourceLocator(
                sourceConversationID: "source-\(id)",
                sourceMessageID: "message-\(id)",
                sourcePartID: "part-\(id)",
                range: QuoteTextRange(utf16Start: 0, utf16Length: max(1, snapshot.utf16.count))
            ),
            snapshot: snapshot,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}

private enum W1SendConfirmationTestFailure: Error {
    case expectedConfirmationHandle
}

private struct W1SendConfirmationFixture {
    let store: PersistenceStore
    let managedFiles: ManagedFileStore
    let supportRoot: URL
    let backend: W1ConfirmationSecretBackend
    let credentials: CredentialStore
    let provider: Stage2ScriptedProvider
    let runtime: ConversationRuntime
    let dependencies: AppAssembly.Dependencies
    let defaults: UserDefaults
    let defaultsSuite: String
    let readPlan: W1ConfirmationReadPlan
    let model: AppShellModel

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: supportRoot)
    }
}

private actor W1ConfirmationReadPlan {
    enum Step: Sendable {
        case read
        case noRun
        case inconclusive
        case matchingRun(runID: String, state: RunState)
    }

    private var steps: [Step]
    private var calls = 0
    private var actualReads = 0
    private var commands: [SendCommand] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func intercept(
        _ command: SendCommand,
        returnedRunID: String?,
        operation: AppAssembly.ConfirmationReadOperation
    ) async -> ComposerSendConfirmationResult {
        calls += 1
        commands.append(command)
        let step = steps.isEmpty ? .read : steps.removeFirst()
        switch step {
        case .read:
            actualReads += 1
            return await operation()
        case .noRun:
            return .noRun
        case .inconclusive:
            return .inconclusive
        case .matchingRun(let runID, let state):
            return .matchingRun(runID: runID, state: state)
        }
    }

    func snapshot() -> (Int, Int, [SendCommand]) {
        (calls, actualReads, commands)
    }
}

private final class W1ConfirmationSecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var stores = 0
    private var loadUnavailable = false

    var storeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stores
    }

    func setLoadUnavailable(_ unavailable: Bool) {
        lock.lock(); defer { lock.unlock() }
        loadUnavailable = unavailable
    }

    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        stores += 1
        secrets[key(reference, generation)] = secret.revealed
    }

    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        lock.lock(); defer { lock.unlock() }
        guard !loadUnavailable else {
            throw SecretBackendError.unavailable("test backend is temporarily unavailable")
        }
        return secrets[key(reference, generation)].map(SecretValue.init)
    }

    func delete(_ reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: key(reference, generation))
    }

    private func key(_ reference: CredentialReference, _ generation: Int) -> String {
        "\(reference.id)#\(generation)"
    }
}
