import Foundation
import Testing

@testable import ZenAgent

/// Shared I05 fixtures live in the first test file so the four RED suites exercise
/// the same persistence and credential boundaries without adding a fifth source file.
enum I05RuntimeTestFixtures {

    static let conversationID = "conversation-i05"
    static let instanceID = ProviderInstanceID(rawValue: "provider-instance-i05")
    static let modelID = ModelID(rawValue: "fake-model")
    static let credentialReference = CredentialReference(id: "credential-i05")

    static func makeFixture(
        credentialReference: CredentialReference? = nil,
        attachCredential: Bool = true,
        provisionCredential: Bool = true
    ) throws -> (
        store: PersistenceStore,
        credentials: CredentialStore,
        instance: ProviderInstance
    ) {
        let reference = credentialReference ?? Self.credentialReference
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        if provisionCredential {
            try credentials.provision(
                SecretValue("i05-test-secret"),
                as: reference
            )
        }

        let instance = ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "I05 provider",
            baseURL: URL(string: "https://fake.invalid"),
            configRevision: .initial,
            credentialReference: attachCredential ? reference : nil
        )
        try store.createProviderInstance(instance)
        try store.database.write { db in
            try Fixtures.conversation(id: conversationID).insert(db)
        }
        return (store, credentials, instance)
    }

    static func command(
        text: String = "question",
        modelID: ModelID = Self.modelID,
        maxProviderSteps: Int = 4
    ) -> SendCommand {
        SendCommand(
            conversationID: conversationID,
            text: text,
            providerInstanceID: instanceID,
            modelID: modelID,
            maxProviderSteps: maxProviderSteps
        )
    }
}

/// A callback recorder makes the stop test wait for a business event rather than for a
/// clock. The runtime remains responsible for persistence; the recorder only observes it.
actor I05EventRecorder {
    private var events: [AgentEvent] = []
    private var stateWaiters: [(state: RunState, continuation: CheckedContinuation<String, Never>)] = []
    private var deltaWaiters: [CheckedContinuation<(runID: String, partID: String, delta: String), Never>] = []

    func append(_ event: AgentEvent) {
        events.append(event)

        if case .runStateChanged(let runID, let state) = event {
            let waiters = stateWaiters.filter { $0.state == state }
            stateWaiters.removeAll { $0.state == state }
            for waiter in waiters {
                waiter.continuation.resume(returning: runID)
            }
        }

        if case .messagePartDelta(let runID, let partID, let delta) = event {
            let waiters = deltaWaiters
            deltaWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: (runID, partID, delta))
            }
        }
    }

    func waitForState(_ state: RunState) async -> String {
        if let runID = events.compactMap({ event -> String? in
            guard case .runStateChanged(let runID, let eventState) = event,
                  eventState == state else { return nil }
            return runID
        }).first {
            return runID
        }

        return await withCheckedContinuation { continuation in
            stateWaiters.append((state, continuation))
        }
    }

    func waitForFirstDelta() async -> (runID: String, partID: String, delta: String) {
        if let event = events.first(where: {
            if case .messagePartDelta = $0 { return true }
            return false
        }), case .messagePartDelta(let runID, let partID, let delta) = event {
            return (runID, partID, delta)
        }

        return await withCheckedContinuation { continuation in
            deltaWaiters.append(continuation)
        }
    }

    func allEvents() -> [AgentEvent] { events }
}

@Suite("Conversation runtime")
struct ConversationRuntimeTests {

    private func expectNoCommittedTurn(
        in fixture: (
            store: PersistenceStore,
            credentials: CredentialStore,
            instance: ProviderInstance
        )
    ) throws {
        #expect(
            try fixture.store.messages(inConversation: I05RuntimeTestFixtures.conversationID).isEmpty,
            "pre-commit failure must not leave a user message"
        )
        #expect(
            try fixture.store.activeParentRuns(inConversation: I05RuntimeTestFixtures.conversationID).isEmpty,
            "pre-commit failure must not leave an active Parent Run"
        )
    }

    @Test("a missing conversation fails before the send commit")
    func missingConversationLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let command = SendCommand(
            conversationID: "missing-conversation",
            text: "question",
            providerInstanceID: fixture.instance.id,
            modelID: I05RuntimeTestFixtures.modelID,
            maxProviderSteps: 4
        )

        do {
            _ = try await runtime.send(command)
            #expect(false, "a missing conversation must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("send commits the user turn, freezes the snapshot, and completes text output")
    func sendRunsTheTextOnlyVerticalSlice() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [
                .textDelta("hello"),
                .textDelta(" world"),
                .finish(.stop),
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(
            I05RuntimeTestFixtures.command(maxProviderSteps: 7)
        )

        let messages = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        )
        #expect(messages.count == 2)
        guard let assistant = messages.first(where: { $0.role == .assistant }) else {
            #expect(false, "the provider output must be bound to an assistant response")
            return
        }

        let parts = try fixture.store.parts(ofMessage: assistant.id)
        #expect(parts.count == 1)
        #expect(parts.first?.state == .completed)
        #expect(try fixture.store.text(ofPart: parts[0].id) == "hello world")

        let run = try fixture.store.run(id: runID)
        #expect(run?.state == .completed)
        #expect(run?.endReason == .completed)
        guard let encodedSnapshot = run?.executionSnapshot else {
            #expect(false, "preparing must write the execution snapshot exactly once")
            return
        }
        let snapshot = try ExecutionSnapshotCodec.decode(encodedSnapshot)
        #expect(snapshot.maxProviderSteps == 7)
        #expect(snapshot.modelCapabilities == [.text, .streaming])
    }

    @Test("an unsupported model fails before the atomic send commit")
    func unsupportedModelLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        var failure: Error?
        do {
            _ = try await runtime.send(
                I05RuntimeTestFixtures.command(modelID: ModelID(rawValue: "unknown-model"))
            )
        } catch {
            failure = error
        }

        #expect(failure != nil)
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("a non-streaming model fails before the send commit")
    func nonStreamingModelLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command())
            #expect(false, "a non-streaming model must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("invalid max steps fails before the send commit")
    func invalidMaxStepsLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command(maxProviderSteps: 0))
            #expect(false, "zero maxProviderSteps must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("a missing provider instance fails before the send commit")
    func missingProviderInstanceLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let command = SendCommand(
            conversationID: I05RuntimeTestFixtures.conversationID,
            text: "question",
            providerInstanceID: ProviderInstanceID(rawValue: "missing-provider-instance"),
            modelID: I05RuntimeTestFixtures.modelID,
            maxProviderSteps: 4
        )

        do {
            _ = try await runtime.send(command)
            #expect(false, "a missing provider instance must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("a missing credential reference fails before the send commit")
    func missingCredentialReferenceLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture(attachCredential: false)
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command())
            #expect(false, "an unattached credential must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("missing credential metadata fails before the send commit")
    func missingCredentialMetadataLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture(provisionCredential: false)
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command())
            #expect(false, "missing credential metadata must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("unavailable credential metadata fails before the send commit")
    func unavailableCredentialLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        try fixture.credentials.logout(I05RuntimeTestFixtures.credentialReference)
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command())
            #expect(false, "an unavailable credential must be rejected")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("request seed construction failure leaves no half state")
    func requestSeedFailureLeavesNoHalfState() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = I05FailingProvider(
            failure: .transportFailure("stream must not start"),
            instanceID: fixture.instance.id,
            seedFailure: true
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        do {
            _ = try await runtime.send(I05RuntimeTestFixtures.command())
            #expect(false, "request seed construction must be able to fail pre-commit")
        } catch {
            // Expected preparation failure.
        }
        try expectNoCommittedTurn(in: fixture)
    }

    @Test("a post-commit snapshot failure preserves the user turn and records a failed run")
    func snapshotFailureAfterCommitPreservesBusinessObject() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let store = fixture.store
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [.finish(.stop)]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in
                guard case .runAccepted(let runID, _) = event else { return }
                try? store.database.write { db in
                    try db.execute(
                        sql: "UPDATE agentRun SET executionSnapshot = ? WHERE id = ?",
                        arguments: ["already-complete", runID]
                    )
                }
            }
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let messages = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        )
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        #expect(try fixture.store.activeParentRuns(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).isEmpty)
        let run = try fixture.store.run(id: runID)
        #expect(run?.state == .failed)
        #expect(run?.endReason == .providerFailed)
        #expect(run?.activeSlot == nil)
    }
}
