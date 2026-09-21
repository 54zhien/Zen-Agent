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

    static func makeFixture() throws -> (
        store: PersistenceStore,
        credentials: CredentialStore,
        instance: ProviderInstance
    ) {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("i05-test-secret"),
            as: credentialReference
        )

        let instance = ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "I05 provider",
            baseURL: URL(string: "https://fake.invalid"),
            configRevision: .initial,
            credentialReference: credentialReference
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
        #expect(
            try fixture.store.messages(inConversation: I05RuntimeTestFixtures.conversationID).isEmpty,
            "steps 1-7 must not leave a user message behind"
        )
        #expect(
            try fixture.store.activeParentRuns(inConversation: I05RuntimeTestFixtures.conversationID).isEmpty,
            "steps 1-7 must not leave a parent run behind"
        )
    }
}
