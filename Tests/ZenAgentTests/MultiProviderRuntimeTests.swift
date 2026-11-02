import Foundation
import Testing

@testable import ZenAgent

@Suite("Multiple provider Runtime routing")
struct MultiProviderRuntimeTests {
    private struct Fixture {
        let store: PersistenceStore
        let credentials: CredentialStore
        let conversationID: String
        let openAIInstance: ProviderInstance
        let deepSeek: FakeProvider
        let openAI: FakeProvider
    }

    private func makeFixture() throws -> Fixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let deepSeekReference = CredentialReference(id: "multi-provider-deepseek")
        let openAIReference = CredentialReference(id: "multi-provider-openai")
        try credentials.provision(SecretValue("deepseek-test-key"), as: deepSeekReference)
        try credentials.provision(SecretValue("openai-test-key"), as: openAIReference)

        let conversationID = "multi-provider-\(UUID().uuidString)"
        let openAIInstance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "openai-instance-\(UUID().uuidString)"),
            providerID: .openAI,
            displayName: "OpenAI",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: openAIReference
        )
        try store.createProviderInstance(openAIInstance)
        try store.database.write { db in
            try Fixtures.conversation(id: conversationID).insert(db)
        }

        return Fixture(
            store: store,
            credentials: credentials,
            conversationID: conversationID,
            openAIInstance: openAIInstance,
            deepSeek: FakeProvider(
                id: .deepSeek,
                modelNames: ["deepseek-model"],
                capabilities: [.text, .streaming],
                scriptedEvents: [.textDelta("DeepSeek response"), .finish(.stop)]
            ),
            openAI: FakeProvider(
                id: .openAI,
                instanceID: openAIInstance.id,
                modelNames: ["openai-model"],
                capabilities: [.text, .streaming],
                scriptedEvents: [.textDelta("OpenAI response"), .finish(.stop)]
            )
        )
    }

    private func command(for fixture: Fixture) -> SendCommand {
        SendCommand(
            conversationID: fixture.conversationID,
            text: "route to OpenAI",
            providerInstanceID: fixture.openAIInstance.id,
            modelID: ModelID(rawValue: "openai-model"),
            maxProviderSteps: 4,
            submissionID: "multi-provider-send-\(UUID().uuidString)"
        )
    }

    @Test("new Run selects its instance Provider while both adapters are registered")
    func newRunUsesSelectedProvider() async throws {
        let fixture = try makeFixture()
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, fixture.openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(command(for: fixture))
        let run = try #require(try fixture.store.run(id: runID))
        let snapshot = try ExecutionSnapshotCodec.decode(
            #require(run.executionSnapshot)
        )
        let messages = try fixture.store.messages(inConversation: fixture.conversationID)
        let response = try #require(messages.first(where: { $0.role == .assistant }))
        let parts = try fixture.store.parts(ofMessage: response.id)

        #expect(snapshot.providerID == .openAI)
        #expect(snapshot.providerAdapterRevision == fixture.openAI.adapterRevision)
        #expect(try fixture.store.text(ofPart: #require(parts.first).id) == "OpenAI response")
    }

    @Test("fresh dispatch rejects an instance Provider that disagrees with the frozen snapshot")
    func freshDispatchRejectsStoredProviderMismatch() async throws {
        let fixture = try makeFixture()
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, fixture.openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )

        let runID = try await fixture.store.memoryAccessGate.withWrite {
            let runID = try await runtime.start(command(for: fixture))
            try fixture.store.database.write { db in
                try db.execute(
                    sql: "UPDATE providerInstance SET providerID = ? WHERE id = ?",
                    arguments: [ProviderID.deepSeek.rawValue, fixture.openAIInstance.id.rawValue]
                )
            }
            return runID
        }
        try await runtime.waitForCompletion(runID: runID)

        let run = try #require(try fixture.store.run(id: runID))
        let step = try #require(try fixture.store.steps(inRun: runID).first)
        #expect(run.state == .failed)
        #expect(run.endReason == .providerFailed)
        #expect(step.providerStartedAt == nil)
    }

    @Test("reconstruction refuses a missing or changed frozen Provider adapter")
    func frozenReconstructionDoesNotFallback() async throws {
        let fixture = try makeFixture()
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, fixture.openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        let runID = try await runtime.send(command(for: fixture))
        let run = try #require(try fixture.store.run(id: runID))
        let snapshot = try ExecutionSnapshotCodec.decode(#require(run.executionSnapshot))

        let missing = try ModelProviderRegistry(providers: [fixture.deepSeek])
        let missingRebuilder = RunRequestRebuilder(
            store: fixture.store,
            providerRegistry: missing,
            toolRegistry: .empty,
            credentials: fixture.credentials
        )
        var missingFailure: Error?
        do {
            _ = try missingRebuilder.initialRequest(for: run, snapshot: snapshot, history: [])
        } catch {
            missingFailure = error
        }
        let missingIsIncompatible: Bool
        if let error = missingFailure as? RunRequestRebuildError,
           case .incompatibleSnapshot = error {
            missingIsIncompatible = true
        } else {
            missingIsIncompatible = false
        }
        #expect(missingIsIncompatible)

        let revised = try ModelProviderRegistry(providers: [
            RevisionedModelProvider(base: fixture.openAI, revision: "openai-responses.v2")
        ])
        let revisedRebuilder = RunRequestRebuilder(
            store: fixture.store,
            providerRegistry: revised,
            toolRegistry: .empty,
            credentials: fixture.credentials
        )
        var revisionFailure: Error?
        do {
            _ = try revisedRebuilder.initialRequest(for: run, snapshot: snapshot, history: [])
        } catch {
            revisionFailure = error
        }
        let revisionIsIncompatible: Bool
        if let error = revisionFailure as? RunRequestRebuildError,
           case .incompatibleSnapshot = error {
            revisionIsIncompatible = true
        } else {
            revisionIsIncompatible = false
        }
        #expect(revisionIsIncompatible)
    }

    @Test("an explicit Child target dispatches through its own frozen Provider")
    func explicitChildUsesFrozenProvider() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let childReference = CredentialReference(id: "multi-provider-child-openai")
        try fixture.credentials.provision(SecretValue("multi-provider-child-key"), as: childReference)
        let childTarget = DelegationModelTarget(
            providerInstanceID: ProviderInstanceID(rawValue: "multi-provider-child-instance"),
            modelID: ModelID(rawValue: "openai-child-model")
        )
        try fixture.store.createProviderInstance(ProviderInstance(
            id: childTarget.providerInstanceID,
            providerID: .openAI,
            displayName: "OpenAI Child",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: childReference
        ))
        try fixture.store.setDelegationConfiguration(enabled: true, explicitModelTarget: childTarget)

        let parentLedger = Stage2ProviderLedger()
        let parent = Stage2ScriptedProvider(ledger: parentLedger, scripts: [
            .events([
                .toolCall(ProviderToolCall(
                    id: "multi-provider-delegation-call",
                    index: 0,
                    name: SubagentDelegationTool.toolID,
                    argumentsJSON: #"{"task":"Use the configured OpenAI Child."}"#
                )),
                .finish(.toolCalls),
            ]),
            .events([.textDelta("Parent continued from OpenAI"), .finish(.stop)]),
        ])
        let child = FakeProvider(
            id: .openAI,
            modelNames: [childTarget.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [.textDelta("OpenAI Child answer"), .finish(.stop)]
        )
        let registry = try ModelProviderRegistry(providers: [parent, child])
        let approvals = MultiProviderApprovalLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials,
            onEvent: { await approvals.append($0) }
        )

        let parentRunID = try await runtime.start(I05RuntimeTestFixtures.command(
            text: "Delegate to OpenAI.",
            modelID: Stage2GateFixture.modelID
        ))
        let toolCallID = await approvals.waitForApproval()
        let parentRun = try #require(try fixture.store.run(id: parentRunID))
        let parentSnapshot = try ExecutionSnapshotCodec.decode(#require(parentRun.executionSnapshot))
        let binding = try #require(parentSnapshot.delegation?.explicitModelBinding)
        #expect(binding.providerID == .openAI)
        #expect(binding.providerAdapterRevision == child.adapterRevision)
        #expect(binding.requestConfigSeed.providerInstanceID == childTarget.providerInstanceID)

        try await runtime.approve(toolCallID: toolCallID)
        try await runtime.waitForCompletion(runID: parentRunID)

        let runs = try fixture.store.runs(inConversation: I05RuntimeTestFixtures.conversationID)
        let childRun = try #require(runs.first(where: { $0.kind == .child }))
        let childSnapshot = try ExecutionSnapshotCodec.decode(#require(childRun.executionSnapshot))
        #expect(childRun.state == .completed)
        #expect(childSnapshot.providerID == .openAI)
        #expect(childSnapshot.providerAdapterRevision == child.adapterRevision)
        #expect(childSnapshot.prompt.providerAdapterInstructions == child.adapterPromptInstructions)
        #expect(childRun.requestConfigSeed.providerInstanceID == childTarget.providerInstanceID)

        let parentRequests = await parentLedger.requestsSnapshot()
        #expect(parentRequests.count == 2)
        #expect(parentRequests.last?.messages.contains { message in
            guard case .toolResult(_, let content) = message else { return false }
            return content == "OpenAI Child answer"
        } == true)
    }

    @Test("parallel Provider calls run in output order and return each result by call ID")
    func toolCallsRoundTripThroughRuntimeInOutputOrder() async throws {
        let fixture = try makeFixture()
        let ledger = MultiProviderRequestLedger()
        let openAI = IndexedToolCallProvider(ledger: ledger)
        let registry = try ModelProviderRegistry(providers: [fixture.deepSeek, openAI])
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials,
            toolRegistry: try Fixtures.automaticallyAllowedRegistry(
                in: fixture.store,
                tools: [CalculatorTool()]
            )
        )

        let runID = try await runtime.send(command(for: fixture))
        let run = try #require(try fixture.store.run(id: runID))
        let requests = await ledger.requestsSnapshot()
        #expect(run.state == .completed)
        #expect(requests.count == 2)

        let continuation = try #require(requests.last)
        let assistantCalls = try #require(continuation.messages.compactMap { message -> [ProviderToolCall]? in
            guard case .assistant(_, _, let calls) = message else { return nil }
            return calls.isEmpty ? nil : calls
        }.first)
        #expect(assistantCalls == [
            ProviderToolCall(
                id: "call_output_first",
                index: 0,
                name: CalculatorTool.toolID,
                argumentsJSON: #"{"expression":"3 + 4"}"#
            ),
            ProviderToolCall(
                id: "call_output_second",
                index: 1,
                name: CalculatorTool.toolID,
                argumentsJSON: #"{"expression":"1 + 2"}"#
            ),
        ])

        let toolResults = continuation.messages.compactMap { message -> (String, String)? in
            guard case .toolResult(let callID, let content) = message else { return nil }
            return (callID, content)
        }
        #expect(toolResults.map { $0.0 } == ["call_output_first", "call_output_second"])
        #expect(toolResults.map { $0.1 } == ["7", "3"])
    }
}

private actor MultiProviderRequestLedger {
    private var requests: [ProviderChatRequest] = []

    func append(_ request: ProviderChatRequest) {
        requests.append(request)
    }

    func requestsSnapshot() -> [ProviderChatRequest] { requests }
}

private struct IndexedToolCallProvider: ModelProvider {
    let ledger: MultiProviderRequestLedger
    let id = ProviderID.openAI

    var adapterRevision: String { "openai-indexed-tool-test.v1" }
    var adapterPromptInstructions: String { "Use the indexed tool-call test adapter." }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: ModelID(rawValue: "openai-model"),
            providerInstanceID: instance.id,
            displayName: "OpenAI Test Model",
            capabilities: [.text, .streaming, .tools]
        )]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown test model")
        }
        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://openai.test/v1/responses")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        await ledger.append(request)
        let hasToolResults = request.messages.contains { message in
            if case .toolResult = message { return true }
            return false
        }
        let events: [ProviderStreamEvent] = hasToolResults
            ? [.textDelta("Calculator results received."), .finish(.stop)]
            : [
                .toolCall(ProviderToolCall(
                    id: "call_output_second",
                    index: 2,
                    name: CalculatorTool.toolID,
                    argumentsJSON: #"{"expression":"1 + 2"}"#
                )),
                .toolCall(ProviderToolCall(
                    id: "call_output_first",
                    index: 0,
                    name: CalculatorTool.toolID,
                    argumentsJSON: #"{"expression":"3 + 4"}"#
                )),
                .finish(.toolCalls),
            ]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct RevisionedModelProvider: ModelProvider {
    let base: any ModelProvider
    let revision: String

    var id: ProviderID { base.id }
    var adapterRevision: String { revision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        base.knownModels(for: instance)
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        base.descriptor(for: modelID, in: instance)
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        try base.makeRequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        try await base.stream(request, seed: seed, credentials: credentials)
    }
}

private actor MultiProviderApprovalLedger {
    private var toolCallIDs: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func append(_ event: AgentEvent) {
        guard case .approvalRequired(_, let toolCallID) = event else { return }
        toolCallIDs.append(toolCallID)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: toolCallID) }
    }

    func waitForApproval() async -> String {
        if let toolCallID = toolCallIDs.first { return toolCallID }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
