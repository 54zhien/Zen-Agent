import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 queued Skill and Environment revocation")
struct SkillQueuedErasureTests {
    @Test("a queued extension revocation wins before the owning Run's Provider handoff",
          .timeLimit(.minutes(1)), arguments: ["environment-delete", "skill-disable", "skill-delete"])
    func queuedProviderHandoffSettlesOriginalOwner(action: String) async throws {
        let fixture = try MemoryPromptFixture.make(scripts: [
            .events([.textDelta("This Provider response must never be requested."), .finish(.stop)])
        ])
        let store = fixture.store
        let skills = SkillRuntime(store: store, credentials: fixture.credentials, registry: .empty)
        let environment = EnvironmentRuntime(store: store, credentials: fixture.credentials)
        let item = try skills.saveUser(definition: .init(name: "Queued region", summary: "",
            instructions: "Use the configured region: ${REGION}", environmentKeys: ["REGION"]))
        try await skills.setEnabled(id: item.id, enabled: true)
        let variable = try environment.savePlain(scope: .skill(item.id), key: "REGION", value: "west")

        let writerEntered = MemoryTestLatch()
        let releaseWriter = MemoryTestLatch()
        defer { Task { await releaseWriter.open() } }
        let blocker = Task {
            await store.memoryAccessGate.withWrite {
                await writerEntered.open()
                await releaseWriter.wait()
            }
        }
        await writerEntered.wait()

        // Queue the actual dependency mutation while the gate is held. The Run's
        // synchronous preparation/commit can still capture its frozen references;
        // its later Provider handoff queues behind this writer.
        let revokeAttemptStarted = MemoryTestLatch()
        let revocation = Task {
            await revokeAttemptStarted.open()
            switch action {
            case "environment-delete":
                do {
                    try await environment.delete(id: variable.id)
                    return QueuedRevocationOutcome.completed
                } catch let error as EnvironmentError {
                    return error == .resourceInUse ? .environmentResourceInUse : .other(String(describing: error))
                } catch {
                    return .other(String(describing: error))
                }
            case "skill-disable":
                do {
                    try await skills.setEnabled(id: item.id, enabled: false)
                    return QueuedRevocationOutcome.completed
                } catch let error as SkillError {
                    return error == .resourceInUse ? .skillResourceInUse : .other(String(describing: error))
                } catch {
                    return .other(String(describing: error))
                }
            case "skill-delete":
                do {
                    try await skills.delete(id: item.id)
                    return QueuedRevocationOutcome.completed
                } catch let error as SkillError {
                    return error == .resourceInUse ? .skillResourceInUse : .other(String(describing: error))
                } catch {
                    return .other(String(describing: error))
                }
            default:
                return .other("unknown action")
            }
        }
        await revokeAttemptStarted.wait()
        for _ in 0..<100 { await Task.yield() }

        var command = fixture.command(text: "Perform the regional action")
        command.selectedSkillIDs = [item.id]
        let runID = try await fixture.runtime.start(command,
            creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))

        var providerStepWasRecorded = false
        for _ in 0..<1_000 {
            let steps = try store.steps(inRun: runID)
            if !steps.isEmpty {
                providerStepWasRecorded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(providerStepWasRecorded)
        // The writer remains active while the Run advances to its gated handoff.
        for _ in 0..<100 { await Task.yield() }
        let requestsWhileBlocked = await fixture.ledger.requestsSnapshot()
        #expect(requestsWhileBlocked.isEmpty)

        await releaseWriter.open()
        await blocker.value
        let revocationOutcome = await revocation.value
        try await fixture.runtime.waitForCompletion(runID: runID)

        switch action {
        case "environment-delete":
            #expect(revocationOutcome == .environmentResourceInUse)
        case "skill-disable", "skill-delete":
            #expect(revocationOutcome == .skillResourceInUse)
        default:
            Issue.record("Unknown revocation case")
        }

        let settledRun = try store.run(id: runID)
        #expect(settledRun?.state == .failed)
        #expect(settledRun?.endReason == .dependencyUnavailable)
        #expect(settledRun?.activeSlot == nil)
        let requestsAfterSettlement = await fixture.ledger.requestsSnapshot()
        #expect(requestsAfterSettlement.isEmpty)

        switch action {
        case "environment-delete":
            let pendingEnvironment = try environment.list().first(where: { $0.id == variable.id })
            #expect(pendingEnvironment?.pendingDeletion == true)
            try await environment.delete(id: variable.id)
            let remainingEnvironment = try environment.list()
            #expect(remainingEnvironment.allSatisfy { $0.id != variable.id })
        case "skill-disable":
            let disabledSkill = try skills.list().first(where: { $0.id == item.id })
            #expect(disabledSkill?.enabled == false)
            try await skills.setEnabled(id: item.id, enabled: false)
            let retainedSkill = try skills.list().first(where: { $0.id == item.id })
            #expect(retainedSkill?.enabled == false)
            let retainedEnvironment = try environment.list()
            #expect(retainedEnvironment.contains(where: { $0.id == variable.id }))
        case "skill-delete":
            let pendingSkill = try skills.list().first(where: { $0.id == item.id })
            #expect(pendingSkill?.pendingDeletion == true)
            try await skills.delete(id: item.id)
            let remainingSkills = try skills.list()
            #expect(remainingSkills.allSatisfy { $0.id != item.id })
            let remainingEnvironment = try environment.list()
            #expect(remainingEnvironment.allSatisfy { $0.id != variable.id })
        default:
            break
        }
    }
}

private enum QueuedRevocationOutcome: Sendable, Equatable {
    case environmentResourceInUse
    case skillResourceInUse
    case completed
    case other(String)
}
