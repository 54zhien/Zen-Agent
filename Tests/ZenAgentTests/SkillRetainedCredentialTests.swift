import Foundation
import Testing
@testable import ZenAgent

@Suite("Retained provider credentials remain protected content")
struct SkillRetainedCredentialTests {
    @Test("reauthentication cannot make a still-active frozen credential acceptable as Skill or Plain content",
          .timeLimit(.minutes(1)))
    @MainActor
    func retainedCredentialCannotBecomeWorkflowContent() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        let old = CredentialReference(id: "retained-provider-old")
        let fresh = CredentialReference(id: "retained-provider-fresh")
        let oldValue = "fixture-detached-provider-key-A"
        try credentials.provision(SecretValue(oldValue), as: old)
        let instance = ProviderInstance(id: .init(rawValue: "retained-provider"), providerID: .deepSeek,
            displayName: "Retained credential fixture", baseURL: nil,
            configRevision: .initial, credentialReference: old)
        try store.createProviderInstance(instance)
        let box = Stage2StreamBox(), ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: ledger, scripts: [
            .holding(prefix: [], box: box), .events([.textDelta("New request finished"), .finish(.stop)])
        ])
        let runtime = ConversationRuntime(store: store, provider: provider, credentials: credentials)
        let original = SendCommand(conversationID: "retained-original", text: "Hold the original request",
            providerInstanceID: instance.id, modelID: Stage2GateFixture.modelID, maxProviderSteps: 4,
            submissionID: "retained-original-send")
        let originalID = try await runtime.start(original,
            creatingConversationIfMissing: Fixtures.conversation(id: original.conversationID))
        defer { Task { try? await runtime.stop(runID: originalID) } }
        await box.waitUntilReady()
        #expect(try store.run(id: originalID)?.state.isTerminal == false)
        let editor = ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            makeCredentialReference: { fresh })
        editor.apiKey = "fixture-current-provider-key-B"
        await editor.reauthenticate()
        #expect(editor.errorMessage == nil)
        #expect(try store.providerInstance(id: instance.id)?.credentialReference == fresh)
        #expect(try credentials.resolve(frozenReference: old, generation: 1)?.revealed == oldValue)
        let skills = SkillRuntime(store: store, credentials: credentials, registry: .empty)
        let environment = EnvironmentRuntime(store: store, credentials: credentials)
        let unexpectedPlain = try? environment.savePlain(key: "OLD_KEY_TEXT", value: oldValue)
        let unexpectedSkill = try? skills.saveUser(definition: .init(name: "Old credential", summary: "", instructions: oldValue))
        #expect(unexpectedPlain == nil)
        #expect(unexpectedSkill == nil)
        if let unexpectedSkill {
            try await skills.setEnabled(id: unexpectedSkill.id, enabled: true)
            var next = SendCommand(conversationID: "retained-next", text: "Explain this workflow",
                providerInstanceID: instance.id, modelID: Stage2GateFixture.modelID, maxProviderSteps: 4,
                submissionID: "retained-next-send")
            next.selectedSkillIDs = [unexpectedSkill.id]
            let nextID = try await runtime.start(next,
                creatingConversationIfMissing: Fixtures.conversation(id: next.conversationID))
            try await runtime.waitForCompletion(runID: nextID)
        }
        let requests = await ledger.requestsSnapshot()
        #expect(!requests.dropFirst().contains { String(describing: $0.messages).contains(oldValue) })
        try await runtime.stop(runID: originalID)
        try await runtime.waitForCompletion(runID: originalID)
    }
}
