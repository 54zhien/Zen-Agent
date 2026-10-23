import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 actual Skill request boundary")
struct SkillPromptIntegrationTests {
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
        let run = try #require(fixture.store.run(id: runID))
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
