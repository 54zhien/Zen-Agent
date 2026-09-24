import Foundation
import GRDB
import Testing

@testable import ZenAgent

private enum ShellCredentialSeed {
    case none
    case active
    case missingSecret
    case unreadableSecret
}

private enum RouterLoadFailure: Error {
    case unavailable
}

@Suite("App shell wiring")
@MainActor
struct AppShellWiringTests {
    @Test("zeroConfigurationDoesNotCreateConversationOrEnableSend")
    func zeroConfigurationDoesNotCreateConversationOrEnableSend() throws {
        let fixture = try makeFixture(seed: .none, createInstance: false, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let initialCount = try conversationCount(in: fixture.store)
        let originalConversationID = fixture.model.conversationID
        fixture.model.newConversation()
        let finalCount = try conversationCount(in: fixture.store)

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane == nil)
        #expect(fixture.model.actionBridge == nil)
        #expect(fixture.model.conversationID != originalConversationID)
        #expect(initialCount == 0)
        #expect(finalCount == 0)
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("defaultTargetRequiresKnownModelAndResolvedSecret")
    func defaultTargetRequiresKnownModelAndResolvedSecret() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let instance = try #require(try fixture.store.providerInstance(id: fixture.instanceID))
        let metadata = try #require(try fixture.credentials.metadata(for: fixture.reference))
        let descriptors = fixture.provider.knownModels(for: instance)
        let resolved = try #require(try fixture.credentials.resolve(
            frozenReference: metadata.reference,
            generation: metadata.bindingGeneration
        ))

        #expect(descriptors.contains { $0.id == fixture.modelID })
        #expect(resolved.revealed == fixture.secret)
        #expect(fixture.model.canSend)
        #expect(fixture.model.target == AppExecutionTarget(
            providerInstanceID: fixture.instanceID,
            modelID: fixture.modelID
        ))
    }

    @Test("missingSecretIsNotSendableAndExplained")
    func missingSecretIsNotSendableAndExplained() throws {
        let fixture = try makeFixture(seed: .missingSecret)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane == nil)
        #expect(fixture.model.targetMessage == "Key 缺失")
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("unavailableSecretIsNotSendableAndExplainedSeparately")
    func unavailableSecretIsNotSendableAndExplainedSeparately() throws {
        let fixture = try makeFixture(seed: .unreadableSecret)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane == nil)
        #expect(fixture.model.targetMessage == "Keychain 不可用")
        #expect(fixture.model.targetMessage != "Key 缺失")
    }

    @Test("sendPreflightRechecksKeychainAndDisablesTheTarget")
    func sendPreflightRechecksKeychainAndDisablesTheTarget() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        pane.composer.draft.text = "keep after keychain failure"
        fixture.backend.unreadableReferences = [fixture.reference.id]
        let coordinator = ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(!fixture.model.canSend)
        #expect(fixture.model.targetMessage == "Keychain 不可用")
        #expect(coordinator.sendErrorMessage == "Keychain 不可用")
        #expect(coordinator.submission == .idle)
        #expect(pane.composer.draft.text == "keep after keychain failure")
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("firstSendPersistsOneTurnAndParentRun")
    func firstSendPersistsOneTurnAndParentRun() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let command = try #require(ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        ).beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "w1-first-send-submission"
        ))

        let runID = try await ComposerSendTiming.$initiatedAt.withValue(timestamp) {
            try await bridge.start(command)
        }
        try await fixture.runtime.waitForCompletion(runID: runID)

        let conversation = try #require(try fixture.store.conversation(id: command.conversationID))
        let messages = try fixture.store.messages(inConversation: command.conversationID)
        let userMessage = try #require(messages.first)
        let parts = try fixture.store.parts(ofMessage: userMessage.id)
        let parentRuns = try fixture.store.runs(inConversation: command.conversationID)
            .filter { $0.kind == .parent }

        #expect(messages.count == 1)
        #expect(userMessage.role == .user)
        #expect(parts.count == 1)
        #expect(try fixture.store.text(ofPart: parts[0].id) == command.text)
        #expect(parentRuns.count == 1)
        #expect(parentRuns[0].id == runID)
        #expect(parentRuns[0].submissionID == command.submissionID)
        #expect(conversation.title == "")
        #expect(conversation.lifecycle == .visible)
        #expect(!conversation.pinned)
        #expect(conversation.createdAt == timestamp)
        #expect(conversation.updatedAt == timestamp)
        #expect(conversation.userActiveAt == timestamp)
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == [runID])
        #expect(pane.liveStore.state.timeline.turns[0].items.contains(.userText(command.text)))
    }

    @Test("runAcceptedLoadsOwningPaneBeforeRoutingLaterDeltas")
    func runAcceptedLoadsOwningPaneBeforeRoutingLaterDeltas() async throws {
        let router = RunEventRouter()
        var paneALoadCount = 0
        let paneA = try makePane(conversationID: "route-conversation-A") { id -> ConversationTimelineProjection in
            paneALoadCount += 1
            return ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "route-run-A", items: [.userText("first A")])]
            )
        }
        let paneB = try makePane(conversationID: "route-conversation-B") { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "route-run-B", items: [.userText("first B")])]
            )
        }
        #expect(router.registerPane(paneA))
        #expect(router.registerPane(paneB))

        await router.handle(.runAccepted(runID: "route-run-A", conversationID: "route-conversation-A"))
        #expect(paneALoadCount == 1)
        _ = await router.handle(.messagePartStarted(
            runID: "route-run-A",
            messageID: "route-message-A",
            partID: "route-part-A",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "route-run-A", partID: "route-part-A", delta: "reply A"))

        #expect(paneA.liveStore.state.timeline.turns.map(\.runID) == ["route-run-A"])
        #expect(assistantTexts(in: paneA.liveStore.state.timeline) == ["reply A"])
        #expect(paneB.liveStore.state.timeline.turns.map(\.runID) == ["route-run-B"])
        #expect(paneB.liveStore.state.timeline.turns[0].items == [.userText("first B")])
    }

    @Test("eventsWaitingForPaneRebuildFromPersistedTimelineInArrivalOrder")
    func eventsWaitingForPaneRebuildFromPersistedTimelineInArrivalOrder() async throws {
        let router = RunEventRouter()
        await router.handle(.runAccepted(runID: "buffered-run", conversationID: "buffered-conversation"))
        await router.handle(.messagePartStarted(
            runID: "buffered-run",
            messageID: "buffered-message",
            partID: "buffered-part",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "buffered-run", partID: "buffered-part", delta: "saved reply"))

        let pane = try makePane(conversationID: "buffered-conversation") { id in
            persistedTimeline(
                conversationID: id,
                runID: "buffered-run",
                messageID: "buffered-message",
                partID: "buffered-part",
                assistantText: "saved reply"
            )
        }
        #expect(router.registerPane(pane))

        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["buffered-run"])
        #expect(assistantTexts(in: pane.liveStore.state.timeline) == ["saved reply"])
        #expect(pane.liveStore.state.timeline.turns[0].items.filter { item -> Bool in
            if case .assistantText = item { return true }
            return false
        }.count == 1)
    }

    @Test("timelineLoadFailureRetainsOwnershipAndRecoversBufferedEvents")
    func timelineLoadFailureRetainsOwnershipAndRecoversBufferedEvents() async throws {
        let router = RunEventRouter()
        var loadCount = 0
        let pane = try makePane(conversationID: "recover-conversation") { id -> ConversationTimelineProjection in
            loadCount += 1
            if loadCount == 1 { throw RouterLoadFailure.unavailable }
            return persistedTimeline(
                conversationID: id,
                runID: "recover-run",
                messageID: "recover-message",
                partID: "recover-part",
                assistantText: "recovered reply"
            )
        }
        #expect(router.registerPane(pane))

        await router.handle(.runAccepted(runID: "recover-run", conversationID: "recover-conversation"))
        await router.handle(.messagePartStarted(
            runID: "recover-run",
            messageID: "recover-message",
            partID: "recover-part",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "recover-run", partID: "recover-part", delta: "recovered reply"))

        #expect(router.recoveryMessage(for: "recover-conversation") != nil)
        #expect(loadCount == 1)
        #expect(router.retryTimelineLoad(for: "recover-conversation"))
        #expect(router.recoveryMessage(for: "recover-conversation") == nil)
        #expect(loadCount == 2)
        #expect(assistantTexts(in: pane.liveStore.state.timeline) == ["recovered reply"])
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["recover-run"])
    }

    @Test("unregisteredRunEventsAreDroppedWithoutPaneMutation")
    func unregisteredRunEventsAreDroppedWithoutPaneMutation() async throws {
        let router = RunEventRouter()
        let pane = try makePane(conversationID: "known-pane") { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "unknown-run", items: [.userText("keep")])]
            )
        }
        #expect(router.registerPane(pane))
        let before = pane.liveStore.state

        await router.handle(.messagePartStarted(
            runID: "unknown-run",
            messageID: "unknown-message",
            partID: "unknown-part",
            kind: .text
        ))

        #expect(pane.liveStore.state == before)
        #expect(router.diagnostics.contains("Dropped unregistered Run event for unknown-run"))
    }

    @Test("sendPreparationFailureIsVisibleAndKeepsDraft")
    func sendPreparationFailureIsVisibleAndKeepsDraft() async throws {
        let instanceID = ProviderInstanceID(rawValue: "composer-error-instance")
        let modelID = Stage2GateFixture.modelID
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: instanceID,
            displayName: "Test model",
            capabilities: [.text, .streaming]
        )
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in throw ComposerSendFailure.keychainUnavailable },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: "keep this draft",
                selection: ComposerSelection(range: 0..<15),
                references: [],
                attachments: [],
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "composer-error-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(coordinator.sendErrorMessage == "Keychain 不可用")
        #expect(coordinator.submission == .idle)
        #expect(controller.draft.text == "keep this draft")
    }

    @Test("committedSendFailureKeepsTheDurableTurnAndClearsTheDraft")
    func committedSendFailureKeepsTheDurableTurnAndClearsTheDraft() async throws {
        let instanceID = ProviderInstanceID(rawValue: "committed-error-instance")
        let modelID = Stage2GateFixture.modelID
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: instanceID,
            displayName: "Test model",
            capabilities: [.text, .streaming]
        )
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in throw ComposerSendFailure.committed(runID: "durable-run") },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in RunProjection(runID: "durable-run", state: .failed) },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: "already saved",
                selection: ComposerSelection(range: 0..<14),
                references: [],
                attachments: [],
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "committed-error-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(controller.draft.text.isEmpty)
        #expect(coordinator.submission == .idle)
        #expect(coordinator.sendErrorMessage == "消息已保存，但运行未能完成。")
    }

    private func makeFixture(
        seed: ShellCredentialSeed,
        createInstance: Bool = true,
        setDefault: Bool = true
    ) throws -> ShellFixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let metadata = InMemoryCredentialMetadataRepository()
        let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
        let instanceID = ProviderInstanceID(rawValue: "shell-instance-\(UUID().uuidString)")
        let reference = CredentialReference(
            id: "shell-reference-\(UUID().uuidString)",
            kind: .apiKey
        )
        let secret = "shell-test-key-\(UUID().uuidString)"

        if createInstance {
            try store.createProviderInstance(ProviderInstance(
                id: instanceID,
                providerID: .deepSeek,
                displayName: "DeepSeek",
                baseURL: nil,
                configRevision: .initial,
                credentialReference: reference
            ))
        }
        switch seed {
        case .none:
            break
        case .active:
            try credentials.provision(SecretValue(secret), as: reference)
        case .missingSecret:
            try metadata.saveMetadata(CredentialMetadata(
                reference: reference,
                bindingGeneration: 1,
                principalFingerprint: nil,
                status: .active,
                updatedAt: Date()
            ))
        case .unreadableSecret:
            try credentials.provision(SecretValue(secret), as: reference)
            backend.unreadableReferences = [reference.id]
        }

        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([])]
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.AppShell.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if setDefault {
            defaults.set(instanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
            defaults.set(Stage2GateFixture.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
        }
        let model = AppShellModel(dependencies: dependencies, userDefaults: defaults)
        return ShellFixture(
            store: store,
            credentials: credentials,
            backend: backend,
            metadata: metadata,
            provider: provider,
            runtime: runtime,
            instanceID: instanceID,
            modelID: Stage2GateFixture.modelID,
            reference: reference,
            secret: secret,
            defaults: defaults,
            defaultsSuite: suite,
            model: model
        )
    }

    private func makePane(
        conversationID: String,
        loadTimeline: @escaping @MainActor (String) throws -> ConversationTimelineProjection
    ) throws -> ConversationPaneController {
        try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "router-instance"),
                modelID: Stage2GateFixture.modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: loadTimeline
        )
    }

    private func persistedTimeline(
        conversationID: String,
        runID: String,
        messageID: String,
        partID: String,
        assistantText: String
    ) -> ConversationTimelineProjection {
        ConversationTimelineProjection(
            conversationID: conversationID,
            turns: [ConversationTurn(
                runID: runID,
                items: [.userText("prompt"), .assistantText(assistantText)],
                textSourcesByItemIndex: [1: TimelineTextSource(
                    conversationID: conversationID,
                    messageID: messageID,
                    partID: partID,
                    isCompleted: false
                )]
            )]
        )
    }

    private func assistantTexts(in timeline: ConversationTimelineProjection) -> [String] {
        timeline.turns.flatMap { turn in
            turn.items.compactMap { item in
                guard case let .assistantText(text) = item else { return nil }
                return text
            }
        }
    }

    private func conversationCount(in store: PersistenceStore) throws -> Int {
        try store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
        }
    }
}

private struct ShellFixture {
    let store: PersistenceStore
    let credentials: CredentialStore
    let backend: InMemorySecretBackend
    let metadata: InMemoryCredentialMetadataRepository
    let provider: Stage2ScriptedProvider
    let runtime: ConversationRuntime
    let instanceID: ProviderInstanceID
    let modelID: ModelID
    let reference: CredentialReference
    let secret: String
    let defaults: UserDefaults
    let defaultsSuite: String
    let model: AppShellModel
}
