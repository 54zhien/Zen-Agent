import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 actual Skill request boundary")
struct SkillPromptIntegrationTests {
    @Test("enabled workflows route a relevant subset and explicit selection overrides routing")
    func routingReachesActualRequests() async throws {
        let fixture = try MemoryPromptFixture.make()
        let skills = SkillRuntime(store: fixture.store, credentials: fixture.credentials, registry: .empty)
        let first = try skills.saveUser(definition: .init(name: "First", summary: "", instructions: "WORKFLOW_ONE", triggerTerms: ["计算"]))
        let second = try skills.saveUser(definition: .init(name: "Second", summary: "", instructions: "WORKFLOW_TWO", triggerTerms: ["阅读文件"]))
        try await skills.setEnabled(id: first.id, enabled: true)
        try await skills.setEnabled(id: second.id, enabled: true)
        _ = try await fixture.send(text: "你好")
        _ = try await fixture.send(text: "请计算这个数")
        var manual = fixture.command(text: "请计算这个数")
        manual.selectedSkillIDs = [second.id]
        let runID = try await fixture.runtime.start(manual)
        try await fixture.runtime.waitForCompletion(runID: runID)
        let requests = await fixture.ledger.requestsSnapshot()
        func current(_ request: ProviderChatRequest) -> String {
            if case .user(let text) = request.messages.last { return text }; return ""
        }
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }
        #expect(!current(requests[0]).contains("WORKFLOW_"))
        #expect(current(requests[1]).contains("WORKFLOW_ONE"))
        #expect(!current(requests[1]).contains("WORKFLOW_TWO"))
        #expect(current(requests[2]).contains("WORKFLOW_TWO"))
        #expect(!current(requests[2]).contains("WORKFLOW_ONE"))
    }

    @Test("reconstruction uses the original Skill and Environment versions after ordinary edits")
    func frozenReconstruction() async throws {
        let fixture = try MemoryPromptFixture.make()
        let skills = SkillRuntime(store: fixture.store, credentials: fixture.credentials, registry: .empty)
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        let item = try skills.saveUser(definition: .init(name: "Region", summary: "", instructions: "ORIGINAL ${REGION}", environmentKeys: ["REGION"]))
        let variable = try environment.savePlain(key: "REGION", value: "west")
        try await skills.setEnabled(id: item.id, enabled: true)
        var command = fixture.command(text: "Use configured region")
        command.selectedSkillIDs = [item.id]
        let runID = try await fixture.runtime.start(command, creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        try await fixture.runtime.waitForCompletion(runID: runID)
        let persisted = try fixture.store.run(id: runID)
        let run = try #require(persisted)
        let encoded = try #require(run.executionSnapshot)
        let snapshot = try ExecutionSnapshotCodec.decode(encoded)
        try environment.savePlain(id: variable.id, expectedRevisionID: variable.revisionID, key: "REGION", value: "east")
        try skills.saveUser(id: item.id, expectedRevisionID: item.revisionID,
            definition: .init(name: "Region", summary: "", instructions: "REPLACEMENT ${REGION}", environmentKeys: ["REGION"]))
        let request = try RunRequestRebuilder(store: fixture.store, provider: fixture.provider, toolRegistry: .empty, credentials: fixture.credentials)
            .initialRequest(for: run, snapshot: snapshot, history: [])
        guard case .user(let text) = request.messages.last else { Issue.record("Expected frozen user context"); return }
        #expect(text.contains("ORIGINAL west"))
        #expect(!text.contains("REPLACEMENT") && !text.contains("east"))
    }

    @Test("a configured Secret reference reaches the frozen dependency but its bytes never enter the request")
    func secretReferenceIsNotPromptContent() async throws {
        let fixture = try MemoryPromptFixture.make()
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: fixture.store)
        let instance = try fixture.store.providerInstance(id: fixture.instanceID)
        let providerReference = try #require(instance?.credentialReference)
        try credentials.provision(SecretValue("fixture-persisted-provider-key"), as: providerReference)
        let skills = SkillRuntime(store: fixture.store, credentials: credentials, registry: .empty)
        let environment = EnvironmentRuntime(store: fixture.store, credentials: credentials)
        let variable = try environment.saveSecret(key: "AUTH", value: SecretValue("fixture-private-auth-value"))
        let item = try skills.saveUser(definition: .init(name: "Service", summary: "", instructions: "State service limitations honestly.", environmentKeys: ["AUTH"]))
        try await skills.setEnabled(id: item.id, enabled: true)
        let runtime = ConversationRuntime(store: fixture.store, provider: fixture.provider, credentials: credentials)
        var command = fixture.command(text: "Explain this service")
        command.selectedSkillIDs = [item.id]
        let runID = try await runtime.start(command, creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        try await runtime.waitForCompletion(runID: runID)
        let persisted = try fixture.store.run(id: runID)
        let encoded = try #require(persisted?.executionSnapshot)
        #expect(!encoded.contains("fixture-private-auth-value"))
        #expect(try ExecutionSnapshotCodec.decode(encoded).prompt.skillReferences.first?.environmentReferences == [variable.reference])
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(!String(describing: requests).contains("fixture-private-auth-value"))
        var interpolated = item.definition
        interpolated.instructions = "Use ${AUTH}"
        let updated = try skills.saveUser(id: item.id, expectedRevisionID: item.revisionID, definition: interpolated)
        command.submissionID = UUID().uuidString
        await #expect(throws: EnvironmentError.secretInterpolation) { try await runtime.start(command) }
        #expect(updated.revisionID != item.revisionID)
        #expect(await fixture.ledger.requestsSnapshot().count == 1)
    }

    @Test("a duplicate submission cannot change its Skill payload")
    func changedPayload() async throws {
        let fixture = try MemoryPromptFixture.make()
        let command = fixture.command(text: "hello")
        let first = try await fixture.runtime.start(command, creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        try await fixture.runtime.waitForCompletion(runID: first)
        var changed = command
        changed.selectedSkillIDs = ["missing-skill"]
        await #expect(throws: ConversationRuntimeError.submissionIDPayloadConflict(command.submissionID)) {
            try await fixture.runtime.start(changed)
        }
        #expect(try fixture.store.messages(inConversation: command.conversationID).filter { $0.role == .user }.count == 1)
    }

    @Test("manual activation reaches the actual request as lower-priority user context and pins references")
    func actualRequest() async throws {
        let fixture = try MemoryPromptFixture.make()
        let skills = SkillRuntime(store: fixture.store, credentials: fixture.credentials, registry: .empty)
        let maybeItem = try? skills.saveUser(definition: .init(name: "Concise", summary: "", instructions: "UNIQUE_SKILL_WORKFLOW"))
        #expect(maybeItem != nil)
        guard let item = maybeItem else { return }
        try await skills.setEnabled(id: item.id, enabled: true)
        var command = fixture.command(text: "Current request wins")
        command.selectedSkillIDs = [item.id]
        let runID = try await fixture.runtime.start(command, creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        try await fixture.runtime.waitForCompletion(runID: runID)
        let requests = await fixture.ledger.requestsSnapshot()
        let request = try #require(requests.first)
        #expect(request.messages.contains { if case .user(let content) = $0 { content.contains(item.definition.instructions) } else { false } })
        #expect(!request.messages.contains { if case .system(let content) = $0 { content.contains(item.definition.instructions) } else { false } })
        #expect(request.tools.isEmpty)
        let persistedRun = try fixture.store.run(id: runID)
        let run = try #require(persistedRun)
        let snapshot = try #require(run.executionSnapshot)
        #expect(!snapshot.contains(item.definition.instructions))
        #expect(try ExecutionSnapshotCodec.decode(snapshot).prompt.skillReferences.first?.revisionID == item.revisionID)
    }

    @Test("pure composition puts workflows before the current user request without granting authority")
    func composition() {
        let context = SkillContext(reference: .init(skillID: "s", revisionID: "v", environmentReferences: [], environmentFingerprint: ""),
            name: "Test", instructions: "UNIQUE_SKILL_CONTEXT")
        let request = PromptComposer().compose(.init(modelID: .init(rawValue: "m"), providerAdapterInstructions: "adapter",
            history: [], currentUserMessage: "CURRENT_REQUEST", activatedSkills: [context]))
        let last = request.messages.last
        guard case .user(let text) = last else { Issue.record("Expected user context"); return }
        #expect(text.contains(context.instructions))
        #expect(text.hasSuffix("CURRENT_REQUEST"))
        #expect(request.tools.isEmpty)
    }
}
