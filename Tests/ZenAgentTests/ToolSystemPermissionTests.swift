import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("S6-04b system consent boundary")
struct ToolSystemPermissionTests {
    @Test func alwaysAllowCannotRequestOrExecuteBeforeUserConsent() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        #expect(try await f.complete() == nil)
        #expect(try f.call().state == .waitingForSystemPermissionConsent)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
    }

    @Test func toolApprovalStillPrecedesSystemConsent() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined, policy: .askEveryTime)
        #expect(try await f.complete() == nil)
        #expect(try f.call().state == .waitingForApproval)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
    }

    @Test(arguments: [ToolSystemPermissionState.denied, .restricted, .unavailable])
    func unavailableSystemAccessNeverDispatches(status: ToolSystemPermissionState) async throws {
        let f = try SystemPermissionFixture(status: status)
        _ = try await f.complete()
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolResult(toolCallID: f.call().id) != nil)
    }

    @Test(arguments: [ToolSystemPermissionState.authorized, .notRequired])
    func availableAccessStillCommitsBeforeExecution(status: ToolSystemPermissionState) async throws {
        let f = try SystemPermissionFixture(status: status)
        #expect(try await f.complete()?.content == "permission-result")
        #expect(try f.call().state == .succeeded)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 1)
        #expect(await f.driver.observedDispatch)
    }

    @Test func explicitConsentRequestsOnceWithoutIssuingGrant() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let original = try f.call()
        try #require(original.state == .waitingForSystemPermissionConsent)
        try await f.runtime.resolveSystemPermission(toolCallID: original.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(original.executionIntent)), consent: true)
        #expect(await f.driver.requests == 1)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
        #expect(try f.call().id == original.id)
        #expect(try f.call().executionIntent == original.executionIntent)
        #expect(try f.call().state == .prepared)
        _ = try await f.runtime.executePrepared(toolCallID: original.id)
        #expect(await f.driver.executions == 1)
        #expect(await f.driver.observedDispatch)
    }

    @Test func decliningConsentNeverRequestsAndSettlesOriginalCall() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        try #require(call.state == .waitingForSystemPermissionConsent)
        try await f.runtime.resolveSystemPermission(toolCallID: call.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), consent: false)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.store.toolResult(toolCallID: call.id) != nil)
    }

    @Test func permissionRevocationAfterApprovalIsCheckedBeforeDispatch() async throws {
        let f = try SystemPermissionFixture(status: .authorized, policy: .askEveryTime)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id)
        await f.driver.set(.denied)
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.executions == 0)
    }

    @Test func explicitConversationScopeSurvivesOneCallButNotAnotherSubject() async throws {
        let f = try SystemPermissionFixture(status: .notRequired, policy: .askEveryTime)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id, scope: .conversation)
        let issued = try #require(try f.store.toolGrants(subject: .parentConversation("c")).first)
        #expect(issued.grant.kind == .conversation)
        #expect(issued.grant.issuedFor?.toolCallID == call.id)
        #expect(issued.grant.resource == .notRequired && issued.grant.destination == .notRequired)
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(try f.store.toolGrant(id: issued.id)?.validity == .active)
        #expect(try await f.runtime.complete(agentRunID: "r", providerCallID: "next", toolID: "system_probe",
            argumentsJSON: "{}", batchID: "b", batchSequence: 1)?.content == "permission-result")
        try f.store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "other", messageID: "m2", runID: "r2", runState: .executingTools))
        #expect(try await f.runtime.complete(agentRunID: "r2", providerCallID: "pc2", toolID: "system_probe",
            argumentsJSON: "{}", batchID: "b2", batchSequence: 0) == nil)
        #expect(try f.store.toolCalls(inRun: "r2").first?.state == .waitingForApproval)
        #expect(await f.driver.executions == 2)
    }

    @Test func deniedPolicyCannotIssueConversationGrant() async throws {
        let f = try SystemPermissionFixture(status: .notRequired, policy: .askEveryTime)
        _ = try await f.complete()
        let call = try f.call()
        try f.store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: .deny)
        try f.runtime.approve(toolCallID: call.id, scope: .conversation)
        #expect(try f.call().state == .rejected)
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
        #expect(await f.driver.executions == 0)
    }

    @Test func conversationRevocationRequiresOriginalNewCallApproval() async throws {
        let f = try SystemPermissionFixture(status: .notRequired, policy: .askEveryTime)
        _ = try await f.complete()
        let call = try f.call()
        try f.runtime.approve(toolCallID: call.id, scope: .conversation)
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        let grant = try #require(try f.store.toolGrants(subject: .parentConversation("c")).first)
        try #require(try f.store.revokeToolGrant(id: grant.id))
        #expect(try await f.runtime.complete(agentRunID: "r", providerCallID: "later", toolID: "system_probe",
            argumentsJSON: "{}", batchID: "b", batchSequence: 1) == nil)
        #expect(try f.store.toolCalls(inRun: "r").filter { $0.state == .waitingForApproval }.count == 1)
        #expect(await f.driver.executions == 1)
    }

    @Test(arguments: [ToolSystemPermissionState.authorized, .notDetermined])
    func freshOwnerRecoversInterruptedRequestWithoutPrompting(status: ToolSystemPermissionState) async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        let binding = ToolIntentBinding.make(try #require(call.executionIntent))
        let descriptor = try #require(f.registry.descriptor(id: "system_probe"))
        _ = try f.store.changeToolSystemConsent(id: call.id, expectedAttempt: call.attempt,
            intentBinding: binding, descriptor: descriptor, safetyCap: .unrestricted,
            command: .begin(owner: "terminated-process", requestID: "original-request"))
        await f.driver.set(status)
        let reopened = ToolRuntime(store: f.store, registry: f.registry)
        try await reopened.recoverSystemPermission(toolCallID: call.id)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
        #expect(try f.call().id == call.id && f.call().executionIntent == call.executionIntent)
        if status == .authorized {
            #expect(try f.call().state == .prepared)
            #expect(try f.store.toolSystemConsent(id: call.id)?.phase == .completed)
        } else {
            #expect(try f.call().state == .waitingForSystemPermissionConsent)
            #expect(try f.store.toolSystemConsent(id: call.id)?.phase == .waiting)
        }
        #expect(try f.store.toolGrants(subject: .parentConversation("c")).isEmpty)
    }

    @Test func duplicateConsentDoesNotRequestTwice() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        let binding = ToolIntentBinding.make(try #require(call.executionIntent))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await f.runtime.resolveSystemPermission(toolCallID: call.id,
                        displayedIntentBinding: binding, consent: true)
                }
            }
            await group.waitForAll()
        }
        #expect(await f.driver.requests == 1)
        #expect(await f.driver.executions == 0)
        #expect(try f.call().state == .prepared)
    }

    @Test func staleSystemWitnessDoesNotPromptOrReplaceTheIntent() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        do {
            try await f.runtime.resolveSystemPermission(toolCallID: call.id,
                displayedIntentBinding: "not-the-displayed-call", consent: true)
            Issue.record("Stale system-consent witness must fail")
        } catch { }
        #expect(await f.driver.requests == 0)
        #expect(try f.call().executionIntent == call.executionIntent)
        #expect(try f.call().state == .waitingForSystemPermissionConsent)
    }

    @Test func v15UpgradePreservesOldFailureAndDoesNotInventConsent() throws {
        let url = try Fixtures.scratchPath(name: "system-consent-v15.sqlite")
        defer { Fixtures.cleanUp(url) }
        var old = DatabaseMigrator()
        Migrations.registerV1(&old); Migrations.registerV2(&old); Migrations.registerV3(&old)
        Migrations.registerV4(&old); Migrations.registerV5(&old); Migrations.registerV6(&old)
        Migrations.registerV7(&old); Migrations.registerV8(&old); Migrations.registerV9(&old)
        Migrations.registerV10(&old); Migrations.registerV11(&old); Migrations.registerV12(&old)
        Migrations.registerV13(&old); Migrations.registerV14(&old); Migrations.registerV15(&old)
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: old))
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
            var call = Fixtures.toolCall(id: "old", runID: "r", action: "tool", state: .rejected, intent: "immutable")
            call.failureReason = .policyDenied
            try store.createRejectedToolCall(call, result: ToolResultRecord(toolCallID: "old", payload: "safe", createdAt: Fixtures.epoch))
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try store.toolCall(id: "old")?.failureReason == .policyDenied)
        #expect(try store.toolCall(id: "old")?.executionIntent == "immutable")
        #expect(try store.toolResult(toolCallID: "old")?.payload == "safe")
        #expect(try store.toolSystemConsent(id: "old") == nil)
        try store.database.write { db in
            try db.execute(sql: "UPDATE toolCall SET failureReason = 'systemPermissionDenied' WHERE id = 'old'")
        }
        #expect(try store.toolCall(id: "old")?.failureReason == .systemPermissionDenied)
    }

    @Test(arguments: [true, false])
    func realContinuationProjectsSystemConsentWithoutIssuingGrant(consent: Bool) async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let driver = SystemPermissionDriver(status: .notDetermined)
        let registry = try ToolRegistry(tools: [SystemPermissionProbe(store: f.store, driver: driver)])
        try f.store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: .alwaysAllow)
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: f.instance.id, scripts: [
            [.toolCall(.init(id: "system-call", index: 0, name: "system_probe", argumentsJSON: "{}")), .finish(.toolCalls)],
            [.textDelta("continued after permission decision"), .finish(.stop)]
        ], store: f.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials, toolRegistry: registry)
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        do {
            var cards: [ToolApprovalProjection] = []
            for _ in 0..<1000 {
                cards = try await runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID)
                if !cards.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let card = try #require(cards.first)
            #expect(card.kind == .systemPermission)
            #expect(card.availableDecisions == [.requestSystemPermission, .declineSystemPermission])
            #expect(await driver.requests == 0)
            #expect(await driver.executions == 0)
            try await runtime.resolveToolApproval(card.request(for: consent ? .requestSystemPermission : .declineSystemPermission))
            try await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            #expect(try f.store.run(id: runID)?.state == .completed)
            let calls = try f.store.toolCalls(inRun: runID)
            #expect(calls.count == 1 && calls.first?.id == card.toolCallID)
            #expect(calls.first?.state == (consent ? .succeeded : .rejected))
            #expect(await driver.requests == (consent ? 1 : 0))
            #expect(await driver.executions == (consent ? 1 : 0))
            #expect(try f.store.toolGrants(subject: .parentConversation(I05RuntimeTestFixtures.conversationID)).isEmpty)
            #expect(await ledger.requestsSnapshot().count == 2)
        } catch {
            try? await runtime.stop(runID: runID)
            try? await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            throw error
        }
    }

    @Test func settingsTighteningBlocksSystemRequestFromOldCard() async throws {
        let f = try SystemPermissionFixture(status: .notDetermined)
        _ = try await f.complete()
        let call = try f.call()
        try #require(call.state == .waitingForSystemPermissionConsent)
        try f.store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: .deny)
        try await f.runtime.resolveSystemPermission(toolCallID: call.id,
            displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)), consent: true)
        #expect(try f.call().state == .rejected)
        #expect(await f.driver.requests == 0)
        #expect(await f.driver.executions == 0)
    }
}

private struct SystemPermissionFixture: Sendable {
    let store: PersistenceStore
    let driver: SystemPermissionDriver
    let runtime: ToolRuntime
    let registry: ToolRegistry
    init(status: ToolSystemPermissionState, policy: ToolPersistentPolicy = .alwaysAllow) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        try store.setToolPolicy(toolID: "system_probe", actionID: "probe", descriptorRevision: "1", mode: policy)
        let driver = SystemPermissionDriver(status: status)
        self.store = store; self.driver = driver
        let registry = try ToolRegistry(tools: [SystemPermissionProbe(store: store, driver: driver)])
        self.registry = registry
        runtime = ToolRuntime(store: store, registry: registry)
    }
    func complete() async throws -> ToolExecutionResult? {
        try await runtime.complete(agentRunID: "r", providerCallID: "pc", toolID: "system_probe",
            argumentsJSON: "{}", batchID: "b", batchSequence: 0)
    }
    func call() throws -> ToolCallRecord { try #require(try store.toolCalls(inRun: "r").first) }
}

private actor SystemPermissionDriver {
    var status: ToolSystemPermissionState
    var requests = 0
    var executions = 0
    var observedDispatch = false
    init(status: ToolSystemPermissionState) { self.status = status }
    func set(_ value: ToolSystemPermissionState) { status = value }
    func request() { requests += 1; status = .authorized }
    func execute(dispatched: Bool) { executions += 1; observedDispatch = dispatched }
}

private struct SystemPermissionProbe: ToolSystemPermissionProviding {
    let store: PersistenceStore
    let driver: SystemPermissionDriver
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "system_probe", displayName: "Test capability", description: "Test-only capability",
            inputSchema: .object([:]), revision: "1", sideEffect: .none, approvalRequirement: .notRequired,
            actions: [ToolPolicyActionMetadata(toolID: "system_probe", actionID: "probe", descriptorRevision: "1",
                risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true,
                resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }
    var systemPermissionDescription: String { "Test-only operating system capability" }
    func systemPermissionState(for intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState { await driver.status }
    func requestSystemPermission(for intent: ToolExecutionIntent) async throws { await driver.request() }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "probe", normalizedArgumentsJSON: "{}",
            resource: .notRequired, destination: .notRequired,
            approvalDisclosure: ToolApprovalDisclosure(toolDisplayName: "Test capability", action: "Probe", targetDescription: "Local test",
                keyImpact: "Test-only request"))
    }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        await driver.execute(dispatched: try store.toolCall(id: idempotencyKey)?.state == .dispatched)
        return ToolExecutionResult(content: "permission-result")
    }
}
