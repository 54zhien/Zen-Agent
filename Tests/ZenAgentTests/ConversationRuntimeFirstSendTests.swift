import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation runtime first send")
struct ConversationRuntimeFirstSendTests {

    @Test("first send commits one user turn and one parent run")
    func firstSendCommitsConversationAndUserTurn() async throws {
        let fixture = try FirstSendRuntimeFixture.make()
        let conversationID = "first-send-\(UUID().uuidString)"
        let command = fixture.command(
            conversationID: conversationID,
            text: "hello from the first send"
        )
        let pending = fixture.pendingConversation(id: conversationID)

        let runID = try await fixture.runtime.start(
            command,
            creatingConversationIfMissing: pending
        )

        let conversation = try #require(try fixture.store.conversation(id: conversationID))
        #expect(conversation.id == conversationID)
        #expect(conversation.title == "")
        #expect(conversation.lifecycle == .visible)
        #expect(!conversation.pinned)
        #expect(conversation.createdAt == conversation.updatedAt)
        #expect(conversation.updatedAt == conversation.userActiveAt)

        let userMessages = try fixture.store.messages(inConversation: conversationID)
            .filter { $0.role == .user }
        #expect(userMessages.count == 1)
        let userMessage = try #require(userMessages.first)
        let parts = try fixture.store.parts(ofMessage: userMessage.id)
        #expect(parts.count == 1)
        #expect(parts.map(\.kind) == [.text])
        #expect(parts.map(\.state) == [.completed])
        #expect(try parts.map { try PersistenceStore.decodeTextPayload($0.payload).text }
            == [command.text])

        let parentRuns = try fixture.store.runs(inConversation: conversationID)
            .filter { $0.kind == .parent }
        #expect(parentRuns.count == 1)
        let parentRun = try #require(parentRuns.first)
        #expect(parentRun.id == runID)
        #expect(parentRun.submissionID == command.submissionID)
    }

    @Test("missing or invalid pending conversation keeps the existing guards")
    func missingOrInvalidPendingConversationIsRejected() async throws {
        let fixture = try FirstSendRuntimeFixture.make()

        let missingID = "first-send-missing-\(UUID().uuidString)"
        let missingCommand = fixture.command(conversationID: missingID, text: "missing")
        await #expect(throws: PersistenceError.conversationNotFound(missingID)) {
            try await fixture.runtime.start(missingCommand)
        }
        #expect(try fixture.store.conversation(id: missingID) == nil)
        #expect(try fixture.store.messages(inConversation: missingID).isEmpty)
        #expect(try fixture.store.runs(inConversation: missingID).isEmpty)

        let expectedID = "first-send-expected-\(UUID().uuidString)"
        let wrongID = "first-send-wrong-\(UUID().uuidString)"
        let mismatchedCommand = fixture.command(conversationID: expectedID, text: "mismatch")
        let mismatchedPending = fixture.pendingConversation(id: wrongID)
        await #expect(throws: PersistenceError.conversationNotFound(expectedID)) {
            try await fixture.runtime.start(
                mismatchedCommand,
                creatingConversationIfMissing: mismatchedPending
            )
        }
        #expect(try fixture.store.conversation(id: expectedID) == nil)
        #expect(try fixture.store.conversation(id: wrongID) == nil)
        #expect(try fixture.store.messages(inConversation: expectedID).isEmpty)
        #expect(try fixture.store.runs(inConversation: expectedID).isEmpty)

        let hiddenID = "first-send-hidden-\(UUID().uuidString)"
        let hiddenCommand = fixture.command(conversationID: hiddenID, text: "hidden")
        let hiddenPending = fixture.pendingConversation(
            id: hiddenID,
            lifecycle: .pendingDeletion
        )
        await #expect(throws: PersistenceError.invalidLifecycleTransition(
            expected: .visible,
            actual: .pendingDeletion
        )) {
            try await fixture.runtime.start(
                hiddenCommand,
                creatingConversationIfMissing: hiddenPending
            )
        }
        #expect(try fixture.store.conversation(id: hiddenID) == nil)
        #expect(try fixture.store.messages(inConversation: hiddenID).isEmpty)
        #expect(try fixture.store.runs(inConversation: hiddenID).isEmpty)
    }

    @Test("replaying a first send without pending returns the original run without another message")
    func replayingFirstSendWithoutPendingIsIdempotent() async throws {
        let fixture = try FirstSendRuntimeFixture.make()
        let conversationID = "first-send-replay-\(UUID().uuidString)"
        let command = fixture.command(conversationID: conversationID, text: "replay me")
        let pending = fixture.pendingConversation(id: conversationID)

        let originalRunID = try await fixture.runtime.start(
            command,
            creatingConversationIfMissing: pending
        )

        // Idempotency is checked before the conversation's current sendability.
        try fixture.store.beginDeletion(conversationID: conversationID)
        let messageCountBeforeReplay = try fixture.store.messages(
            inConversation: conversationID
        ).count
        let replayedRunID = try await fixture.runtime.start(command)
        let messageCountAfterReplay = try fixture.store.messages(
            inConversation: conversationID
        ).count

        #expect(try fixture.store.conversationLifecycle(id: conversationID) == .pendingDeletion)
        #expect(replayedRunID == originalRunID)
        #expect(messageCountAfterReplay == messageCountBeforeReplay)
        #expect(try fixture.store.runs(inConversation: conversationID)
            .filter { $0.kind == .parent }.count == 1)
    }
}

private struct FirstSendRuntimeFixture {
    let store: PersistenceStore
    let runtime: ConversationRuntime
    let instanceID: ProviderInstanceID

    static func make() throws -> FirstSendRuntimeFixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let reference = CredentialReference(id: "first-send-credential-\(UUID().uuidString)")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("first-send-test-secret"), as: reference)

        let instanceID = ProviderInstanceID(rawValue: "first-send-provider-\(UUID().uuidString)")
        let instance = ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "First send test provider",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)

        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([])]
        )
        let runtime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials
        )
        return FirstSendRuntimeFixture(
            store: store,
            runtime: runtime,
            instanceID: instanceID
        )
    }

    func command(conversationID: String, text: String) -> SendCommand {
        SendCommand(
            conversationID: conversationID,
            text: text,
            providerInstanceID: instanceID,
            modelID: Stage2GateFixture.modelID,
            maxProviderSteps: Stage2GateFixture.maxProviderSteps,
            submissionID: "first-send-submission-\(UUID().uuidString)"
        )
    }

    func pendingConversation(
        id: String,
        lifecycle: ConversationLifecycle = .visible
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: "",
            createdAt: Fixtures.epoch,
            updatedAt: Fixtures.epoch,
            userActiveAt: Fixtures.epoch,
            pinned: false,
            lifecycle: lifecycle
        )
    }
}
