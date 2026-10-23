import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 Send selection reaches the app-owned conversation boundary")
struct SkillSendWiringTests {
    @Test("the app bridge preserves submission payload conflict when only Skill selection changes")
    func wrapperDoesNotTurnConflictIntoCommitted() async throws {
        let fixture = try MemoryPromptFixture.make()
        let command = fixture.command(text: "same submission identity")
        let originalRunID = try await fixture.runtime.start(command,
            creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        try await fixture.runtime.waitForCompletion(runID: originalRunID)

        let context = ConversationStartContext(conversationID: command.conversationID,
            store: fixture.store, provider: fixture.provider, credentials: fixture.credentials,
            runtime: fixture.runtime, onTargetFailure: { _, _ in })
        var changed = command
        changed.selectedSkillIDs = ["different-skill-selection"]

        await #expect(throws: ConversationRuntimeError.submissionIDPayloadConflict(command.submissionID)) {
            try await context.start(changed, initiatedAt: Date())
        }
        #expect(try fixture.store.run(submissionID: command.submissionID)?.id == originalRunID)
        #expect(try fixture.store.messages(inConversation: command.conversationID).filter { $0.role == .user }.count == 1)
    }
}
