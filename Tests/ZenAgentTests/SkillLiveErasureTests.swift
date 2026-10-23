import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 live Skill dependency revocation")
struct SkillLiveErasureTests {
    @Test("environment deletion, Skill disable and Skill deletion revoke a displayed approval before retry",
          .timeLimit(.minutes(1)), arguments: ["environment-delete", "skill-disable", "skill-delete"])
    func revocationSettlesOriginalApprovedRun(action: String) async throws {
        let effects = SideEffectLedger()
        let tool = Stage2SideEffectTool(ledger: effects)
        let fixture = try MemoryPromptFixture.make(registry: ToolRegistry(tools: [tool]), scripts: [
            .events([.toolCall(.init(id: "skill-pending-\(action)", index: 0,
                name: tool.descriptor.id, argumentsJSON: "{}")), .finish(.toolCalls)]),
            .events([.textDelta("unexpected continuation"), .finish(.stop)])
        ])
        let skills = SkillRuntime(store: fixture.store, credentials: fixture.credentials,
            registry: ToolRegistry(tools: [tool]))
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        let item = try skills.saveUser(definition: .init(name: "Regional action", summary: "",
            instructions: "Use the configured region: ${REGION}", requiredTools: [tool.descriptor.id],
            environmentKeys: ["REGION"]))
        try await skills.setEnabled(id: item.id, enabled: true)
        let variable = try environment.savePlain(scope: .skill(item.id), key: "REGION", value: "west")

        var command = fixture.command(text: "Perform the regional action")
        command.selectedSkillIDs = [item.id]
        let runID = try await fixture.runtime.start(command,
            creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        var displayed: ToolApprovalProjection?
        for _ in 0..<1_000 {
            displayed = try await fixture.runtime.pendingToolApprovals(in: command.conversationID).first
            if displayed != nil { break }
            if try fixture.store.run(id: runID)?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let approval = try #require(displayed, "the real ToolPolicy path should display its approval before revocation")
        let requestsBeforeRevocation = await fixture.ledger.requestsSnapshot()
        #expect(requestsBeforeRevocation.count == 1)
        if let last = requestsBeforeRevocation.first?.messages.last, case .user(let content) = last {
            #expect(content.contains("Use the configured region: west"))
        } else { Issue.record("Expected the actual provider request to contain prepared Skill context") }

        switch action {
        case "environment-delete":
            await #expect(throws: EnvironmentError.resourceInUse) { try await environment.delete(id: variable.id) }
            #expect(try environment.list().first(where: { $0.id == variable.id })?.pendingDeletion == true)
        case "skill-disable":
            await #expect(throws: SkillError.resourceInUse) { try await skills.setEnabled(id: item.id, enabled: false) }
            #expect(try skills.list().first(where: { $0.id == item.id })?.enabled == false)
        case "skill-delete":
            await #expect(throws: SkillError.resourceInUse) { try await skills.delete(id: item.id) }
            #expect(try skills.list().first(where: { $0.id == item.id })?.pendingDeletion == true)
        default:
            Issue.record("Unknown revocation case")
            return
        }
        let grantIDsAfterRevocation = try fixture.store.toolGrantsForSettings().map(\.id)

        // The approval was displayed before revocation. Resolving it must traverse
        // the original Run owner and current dispatch authority, which should settle
        // the Run as dependencyUnavailable without executing or requesting a retry.
        try await fixture.runtime.resolveToolApproval(approval.request(for: .approveOnce))
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(await effects.snapshot().isEmpty)
        #expect(await fixture.ledger.requestsSnapshot().count == 1)
        #expect(try fixture.store.toolGrantsForSettings().map(\.id) == grantIDsAfterRevocation)
        #expect(try fixture.store.run(id: runID)?.endReason == .dependencyUnavailable)
        let remainingApprovals = try await fixture.runtime.pendingToolApprovals(in: command.conversationID)
        #expect(remainingApprovals.isEmpty)

        switch action {
        case "environment-delete":
            try await environment.delete(id: variable.id)
            #expect(try environment.list().allSatisfy { $0.id != variable.id })
        case "skill-disable":
            try await skills.setEnabled(id: item.id, enabled: false)
            #expect(try skills.list().first(where: { $0.id == item.id })?.enabled == false)
            #expect(try environment.list().contains(where: { $0.id == variable.id }))
        case "skill-delete":
            try await skills.delete(id: item.id)
            #expect(try skills.list().allSatisfy { $0.id != item.id })
            #expect(try environment.list().allSatisfy { $0.id != variable.id })
        default: break
        }
    }
}
