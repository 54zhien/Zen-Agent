import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Tool approval UI red probes")
@MainActor
struct ToolApprovalUITests {

    private static let toolID = "stage2_side_effect"
    private static let continuationText = "model continued after the tool decision"

    @Test("waitingForApprovalShowsCardInOwningConversation")
    func waitingForApprovalShowsCardInOwningConversation() async throws {
        let environment = try makeEnvironment(conversationIDs: ["approval-owner-a", "approval-owner-b"])
        let pair = try await startPendingPair(in: environment)

        let cardsA = try await pair.first.runtime.pendingToolApprovals(in: pair.first.conversationID)
        let cardsB = try await pair.second.runtime.pendingToolApprovals(in: pair.second.conversationID)

        #expect(cardsA.map(\.toolCallID) == [pair.first.toolCallID])
        #expect(cardsB.map(\.toolCallID) == [pair.second.toolCallID])
        #expect(!cardsA.contains { $0.toolCallID == pair.second.toolCallID })
        #expect(!cardsB.contains { $0.toolCallID == pair.first.toolCallID })
        #expect(cardsA.first?.conversationID == pair.first.conversationID)
        #expect(cardsB.first?.conversationID == pair.second.conversationID)

        try await stopIfActive(pair.first, in: environment.store)
        try await stopIfActive(pair.second, in: environment.store)
    }

    @Test("approvalCardUsesFrozenExecutionIntent")
    func approvalCardUsesFrozenExecutionIntent() async throws {
        let environment = try makeEnvironment()
        let tool = I07RecordingTool(
            id: "frozen-intent-probe",
            approvalRequirement: .required,
            ledger: I07ToolLedger()
        )
        let disclosureA = makeDisclosure(
            target: "Frozen target: quarterly report",
            impact: "Frozen impact: replace the existing report"
        )
        let rows: [(conversationID: String, runID: String, callID: String, arguments: String, disclosure: ToolApprovalDisclosure)] = [
            ("frozen-a-1", "frozen-run-a-1", "frozen-call-a-1", #"{"target":"request-target-a","revision":1}"#, disclosureA),
            ("frozen-a-2", "frozen-run-a-2", "frozen-call-a-2", #"{"target":"request-target-b","revision":2}"#, disclosureA),
            ("frozen-b-1", "frozen-run-b-1", "frozen-call-b-1", #"{"target":"same-request-target","revision":3}"#, makeDisclosure(
                target: "Frozen target: first destination",
                impact: "Frozen impact: create the first document"
            )),
            ("frozen-b-2", "frozen-run-b-2", "frozen-call-b-2", #"{"target":"same-request-target","revision":3}"#, makeDisclosure(
                target: "Frozen target: second destination",
                impact: "Frozen impact: replace the second document"
            )),
        ]

        for row in rows {
            let intent = try preparedIntent(
                by: tool,
                callID: row.callID,
                argumentsJSON: row.arguments,
                disclosure: row.disclosure
            )
            try persistPendingCall(
                in: environment.store,
                conversationID: row.conversationID,
                runID: row.runID,
                callID: row.callID,
                intent: intent
            )
        }

        // Read each execution intent back from SQLite before asking Runtime to build a
        // display value. The comparison never uses the in-memory value returned by prepare.
        let persistedIntents = try rows.map { row -> ToolExecutionIntent in
            let stored = try #require(environment.store.toolCall(id: row.callID))
            return try decodeIntent(from: stored)
        }
        #expect(persistedIntents[0].normalizedArgumentsJSON != persistedIntents[1].normalizedArgumentsJSON)
        #expect(persistedIntents[2].normalizedArgumentsJSON == persistedIntents[3].normalizedArgumentsJSON)
        #expect(persistedIntents[0].approvalDisclosure == persistedIntents[1].approvalDisclosure)
        #expect(persistedIntents[2].approvalDisclosure != persistedIntents[3].approvalDisclosure)

        let runtime = makeProjectionRuntime(for: environment)
        let approvalsA1 = try await runtime.pendingToolApprovals(in: rows[0].conversationID)
        let approvalsA2 = try await runtime.pendingToolApprovals(in: rows[1].conversationID)
        let approvalsB1 = try await runtime.pendingToolApprovals(in: rows[2].conversationID)
        let approvalsB2 = try await runtime.pendingToolApprovals(in: rows[3].conversationID)
        let cardA1 = try #require(approvalsA1.first)
        let cardA2 = try #require(approvalsA2.first)
        let cardB1 = try #require(approvalsB1.first)
        let cardB2 = try #require(approvalsB2.first)

        #expect(renderedDisclosureText(cardA1) == renderedDisclosureText(cardA2))
        #expect(renderedDisclosureText(cardA1).contains("Frozen target: quarterly report"))
        #expect(renderedDisclosureText(cardA1).contains("Frozen impact: replace the existing report"))
        #expect(renderedDisclosureText(cardB1) != renderedDisclosureText(cardB2))
        #expect(renderedDisclosureText(cardB1).contains("Frozen target: first destination"))
        #expect(renderedDisclosureText(cardB2).contains("Frozen impact: replace the second document"))

        let sources = try #require(sourceFiles())
        let textLines = (sources["App/Conversation/ToolApprovalCardView.swift"] ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.contains("Text(") }
        #expect(textLines.contains { $0.contains("Text(approval.toolDisplayName)") })
        #expect(textLines.contains { $0.contains("Text(approval.action)") })
        #expect(textLines.contains { $0.contains("Text(approval.targetDescription)") })
        #expect(textLines.contains { $0.contains("Text(approval.keyImpact)") })
    }

    @Test("approvalOffersOnlySingleCallDecision")
    func approvalOffersOnlySingleCallDecision() async throws {
        let environment = try makeEnvironment()
        let call = try makePersistedApproval(
            in: environment,
            conversationID: "single-call-decision",
            runID: "single-call-decision-run",
            callID: "single-call-decision-call"
        )
        let runtime = makeProjectionRuntime(for: environment)
        let approvals = try await runtime.pendingToolApprovals(in: call.conversationID)
        let card = try #require(approvals.first)
        let sources = try #require(sourceFiles())
        let cardSource = try #require(sources["App/Conversation/ToolApprovalCardView.swift"])

        #expect(ToolApprovalDecision.allCases == [.approveOnce, .rejectOnce])
        #expect(card.availableDecisions == [.approveOnce, .rejectOnce])
        #expect(ToolApprovalDecision.approveOnce.title == "批准本次")
        #expect(ToolApprovalDecision.rejectOnce.title == "拒绝本次")
        #expect(cardSource.contains("ForEach(ToolApprovalDecision.allCases"))
        #expect(!cardSource.contains("始终允许"))
        #expect(!cardSource.contains("总是允许"))
        #expect(!cardSource.localizedCaseInsensitiveContains("allowAlways"))
        #expect(!cardSource.localizedCaseInsensitiveContains("allowConversation"))
    }

    @Test("approveResumesSameToolCallViaExecuteApproved")
    func approveResumesSameToolCallViaExecuteApproved() async throws {
        let environment = try makeEnvironment(conversationIDs: ["approve-selected", "approve-other"])
        let pair = try await startPendingPair(
            in: environment,
            firstConversationID: "approve-selected",
            secondConversationID: "approve-other"
        )
        let cards = try await pair.first.runtime.pendingToolApprovals(in: pair.first.conversationID)
        let selected = try #require(cards.first { $0.toolCallID == pair.first.toolCallID })
        let request: ToolApprovalRequest = selected.request(for: .approveOnce)

        #expect(request.toolCallID == pair.first.toolCallID)
        #expect(request.conversationID == pair.first.conversationID)
        #expect(!request.runtimeInstanceID.isEmpty)
        #expect(request.decision == .approveOnce)

        try await pair.first.runtime.resolveToolApproval(request)
        try await pair.first.runtime.waitForCompletion(runID: pair.first.runID)

        let calls = try environment.store.toolCalls(inRun: pair.first.runID)
        let call = try #require(calls.first)
        let observations = await environment.sideEffectLedger.snapshot()
        #expect(calls.count == 1)
        #expect(call.id == pair.first.toolCallID)
        #expect(call.state == .succeeded)
        #expect(observations.filter { $0.toolCallID == pair.first.toolCallID }.count == 1)
        #expect(try environment.store.toolCall(id: pair.second.toolCallID)?.state == .waitingForApproval)

        assertApprovalButtonAndTimelineHandoffs()
        try await stopIfActive(pair.second, in: environment.store)
    }

    @Test("rejectPersistsTerminalResultAndContinuesModel")
    func rejectPersistsTerminalResultAndContinuesModel() async throws {
        let environment = try makeEnvironment(conversationIDs: ["reject-selected", "reject-other"])
        let pair = try await startPendingPair(
            in: environment,
            firstConversationID: "reject-selected",
            secondConversationID: "reject-other"
        )
        let cards = try await pair.first.runtime.pendingToolApprovals(in: pair.first.conversationID)
        let selected = try #require(cards.first { $0.toolCallID == pair.first.toolCallID })
        let request: ToolApprovalRequest = selected.request(for: .rejectOnce)

        #expect(request.toolCallID == pair.first.toolCallID)
        #expect(request.conversationID == pair.first.conversationID)
        #expect(request.decision == .rejectOnce)

        try await pair.first.runtime.resolveToolApproval(request)
        try await pair.first.runtime.waitForCompletion(runID: pair.first.runID)

        let call = try #require(try environment.store.toolCall(id: pair.first.toolCallID))
        let result = try #require(try environment.store.toolResult(toolCallID: call.id))
        let requests = await pair.first.providerLedger.requestsSnapshot()
        let observations = await environment.sideEffectLedger.snapshot()
        #expect(call.id == pair.first.toolCallID)
        #expect(call.state == .rejected)
        #expect(result.toolCallID == call.id)
        #expect(result.payload == "Tool execution was rejected by the user.")
        #expect(observations.filter { $0.toolCallID == pair.first.toolCallID }.isEmpty)
        #expect(requests.count == 2)
        #expect(try environment.store.run(id: pair.first.runID)?.state == .completed)
        #expect(try environment.store.toolCall(id: pair.second.toolCallID)?.state == .waitingForApproval)

        guard requests.count > 1 else {
            Issue.record("the model must receive a continuation request after rejection")
            try await stopIfActive(pair.second, in: environment.store)
            return
        }
        let continuationResults = requests[1].messages.compactMap { message -> (String, String)? in
            guard case .toolResult(let toolCallID, let content) = message else { return nil }
            return (toolCallID, content)
        }
        #expect(continuationResults.count == 1)
        #expect(continuationResults.first?.0 == call.providerCallID)
        #expect(continuationResults.first?.1 == result.payload)
        #expect(try assistantText(for: pair.first.runID, in: environment.store) == Self.continuationText)

        assertApprovalButtonAndTimelineHandoffs()
        try await stopIfActive(pair.second, in: environment.store)
    }

    @Test("recoveryRestoresPendingApprovalOnce")
    func recoveryRestoresPendingApprovalOnce() async throws {
        let url = try Fixtures.scratchPath(name: "tool-approval-recovery.sqlite")
        defer { Fixtures.cleanUp(url) }
        let database = try ZenDatabase.open(at: url.path(), migrator: Migrations.makeMigrator())
        let environment = try makeEnvironment(
            conversationIDs: ["approval-recovery"],
            database: database
        )
        let pending = try await startPendingApproval(
            in: environment,
            conversationID: "approval-recovery"
        )
        let originalApprovals = try await pending.runtime.pendingToolApprovals(in: pending.conversationID)
        let originalCard = try #require(originalApprovals.first)
        let originalRequest: ToolApprovalRequest = originalCard.request(for: .approveOnce)
        let liveStore = makeLiveStore(conversationID: pending.conversationID)
        liveStore.reconcilePendingToolApprovals([originalCard])

        let reopenedDatabase = try ZenDatabase.open(at: url.path(), migrator: Migrations.makeMigrator())
        let reopenedStore = PersistenceStore(database: reopenedDatabase)
        let reopenedEnvironment = environment.reusing(store: reopenedStore)
        let reopenedRuntime = makeProjectionRuntime(for: reopenedEnvironment)
        let coldLoadedCards = try await reopenedRuntime.pendingToolApprovals(in: pending.conversationID)
        let coldLoadedCard = try #require(coldLoadedCards.first)
        let coldLoadedRequest: ToolApprovalRequest = coldLoadedCard.request(for: .approveOnce)
        liveStore.reconcilePendingToolApprovals(coldLoadedCards)

        #expect(coldLoadedCards.map(\.toolCallID) == [pending.toolCallID])
        #expect(coldLoadedRequest.toolCallID == originalRequest.toolCallID)
        #expect(coldLoadedRequest.conversationID == originalRequest.conversationID)
        #expect(coldLoadedRequest.runtimeInstanceID != originalRequest.runtimeInstanceID)
        #expect(liveStore.state.pendingToolApprovals.map(\.toolCallID) == [pending.toolCallID])
        let displayedColdCard = try #require(liveStore.state.pendingToolApprovals.first)
        let displayedColdRequest: ToolApprovalRequest = displayedColdCard.request(for: .approveOnce)
        #expect(displayedColdRequest.runtimeInstanceID == coldLoadedRequest.runtimeInstanceID)

        let recoveryEvents = Stage2GateEventRecorder()
        try await RunRecovery(
            store: reopenedStore,
            toolRuntime: ToolRuntime(store: reopenedStore, registry: reopenedEnvironment.toolRegistry),
            credentials: reopenedEnvironment.credentials,
            eventProjection: { event in await recoveryEvents.append(event) }
        ).recover(runID: pending.runID)
        let replayedCallID = await recoveryEvents.waitForApproval()
        let afterRecovery = try await reopenedRuntime.pendingToolApprovals(in: pending.conversationID)
        _ = liveStore.consume(.approvalRequired(runID: pending.runID, toolCallID: replayedCallID))
        liveStore.reconcilePendingToolApprovals(afterRecovery)

        #expect(replayedCallID == pending.toolCallID)
        #expect(afterRecovery.map(\.toolCallID) == [pending.toolCallID])
        #expect(liveStore.state.pendingToolApprovals.map(\.toolCallID) == [pending.toolCallID])

        var staleRequestFailure: Error?
        do {
            try await reopenedRuntime.resolveToolApproval(originalRequest)
        } catch {
            staleRequestFailure = error
        }
        #expect(staleRequestFailure != nil)
        #expect(try reopenedStore.toolCall(id: pending.toolCallID)?.state == .waitingForApproval)

        try await stopIfActive(pending, in: environment.store)
    }

    @Test("settledOrCancelledCallRemovesApprovalCard")
    func settledOrCancelledCallRemovesApprovalCard() async throws {
        let environment = try makeEnvironment()
        let cancelled = try makePersistedApproval(
            in: environment,
            conversationID: "cancelled-approval",
            runID: "cancelled-approval-run",
            callID: "cancelled-approval-call"
        )
        let settled = try makePersistedApproval(
            in: environment,
            conversationID: "settled-approval",
            runID: "settled-approval-run",
            callID: "settled-approval-call"
        )
        let runtime = makeProjectionRuntime(for: environment)
        let cancelledApprovals = try await runtime.pendingToolApprovals(in: cancelled.conversationID)
        let settledApprovals = try await runtime.pendingToolApprovals(in: settled.conversationID)
        let cancelledCard = try #require(cancelledApprovals.first)
        let settledCard = try #require(settledApprovals.first)
        let cancelledRequest: ToolApprovalRequest = cancelledCard.request(for: .approveOnce)
        let settledRequest: ToolApprovalRequest = settledCard.request(for: .rejectOnce)
        let cancelledStore = makeLiveStore(conversationID: cancelled.conversationID)
        let settledStore = makeLiveStore(conversationID: settled.conversationID)
        cancelledStore.reconcilePendingToolApprovals([cancelledCard])
        settledStore.reconcilePendingToolApprovals([settledCard])

        try environment.store.settleToolCallForCancellation(id: cancelled.toolCallID)
        try environment.store.database.write { db in
            try db.execute(
                sql: "UPDATE toolCall SET state = ? WHERE id = ?",
                arguments: [ToolCallState.succeeded.rawValue, settled.toolCallID]
            )
        }

        let cancelledRemaining = try await runtime.pendingToolApprovals(in: cancelled.conversationID)
        let settledRemaining = try await runtime.pendingToolApprovals(in: settled.conversationID)
        cancelledStore.reconcilePendingToolApprovals(cancelledRemaining)
        settledStore.reconcilePendingToolApprovals(settledRemaining)
        #expect(cancelledRemaining.isEmpty)
        #expect(settledRemaining.isEmpty)
        #expect(cancelledStore.state.pendingToolApprovals.isEmpty)
        #expect(settledStore.state.pendingToolApprovals.isEmpty)

        var cancelledFailure: Error?
        do {
            try await runtime.resolveToolApproval(cancelledRequest)
        } catch {
            cancelledFailure = error
        }
        var settledFailure: Error?
        do {
            try await runtime.resolveToolApproval(settledRequest)
        } catch {
            settledFailure = error
        }
        #expect(cancelledFailure != nil)
        #expect(settledFailure != nil)
        #expect(try environment.store.toolCall(id: cancelled.toolCallID)?.state == .notExecuted)
        #expect(try environment.store.toolCall(id: settled.toolCallID)?.state == .succeeded)
    }

    @Test("staleApprovalCannotResolveAnotherConversationCall")
    func staleApprovalCannotResolveAnotherConversationCall() async throws {
        let environment = try makeEnvironment(conversationIDs: ["stale-owner-a", "stale-owner-b"])
        let pair = try await startPendingPair(
            in: environment,
            firstConversationID: "stale-owner-a",
            secondConversationID: "stale-owner-b"
        )
        let approvalsA = try await pair.first.runtime.pendingToolApprovals(in: pair.first.conversationID)
        let cardA = try #require(approvalsA.first { $0.toolCallID == pair.first.toolCallID })
        let request: ToolApprovalRequest = cardA.request(for: .approveOnce)

        let secondInstanceForSameConversation = makeProjectionRuntime(for: environment)
        var sameConversationFailure: Error?
        do {
            try await secondInstanceForSameConversation.resolveToolApproval(request)
        } catch {
            sameConversationFailure = error
        }
        #expect(sameConversationFailure != nil)
        #expect(try environment.store.toolCall(id: pair.first.toolCallID)?.state == .waitingForApproval)
        #expect(try environment.store.toolCall(id: pair.second.toolCallID)?.state == .waitingForApproval)

        var wrongRuntimeFailure: Error?
        do {
            try await pair.second.runtime.resolveToolApproval(request)
        } catch {
            wrongRuntimeFailure = error
        }
        #expect(wrongRuntimeFailure != nil)
        #expect(try environment.store.toolCall(id: pair.first.toolCallID)?.state == .waitingForApproval)
        #expect(try environment.store.toolCall(id: pair.second.toolCallID)?.state == .waitingForApproval)
        let pendingA = try await pair.first.runtime.pendingToolApprovals(in: pair.first.conversationID)
        let pendingB = try await pair.second.runtime.pendingToolApprovals(in: pair.second.conversationID)
        #expect(pendingA.map(\.toolCallID) == [pair.first.toolCallID])
        #expect(pendingB.map(\.toolCallID) == [pair.second.toolCallID])

        try await pair.first.runtime.resolveToolApproval(request)
        try await pair.first.runtime.waitForCompletion(runID: pair.first.runID)
        #expect(try environment.store.toolCall(id: pair.first.toolCallID)?.state == .succeeded)
        #expect(try environment.store.toolCall(id: pair.second.toolCallID)?.state == .waitingForApproval)
        try await stopIfActive(pair.second, in: environment.store)
    }

    @Test("systemPermissionWaitDoesNotShowToolApproval")
    func systemPermissionWaitDoesNotShowToolApproval() async throws {
        let environment = try makeEnvironment()
        let call = try makePersistedApproval(
            in: environment,
            conversationID: "system-consent-wait",
            runID: "system-consent-run",
            callID: "system-consent-call",
            callState: .waitingForSystemPermissionConsent
        )
        let runtime = makeProjectionRuntime(for: environment)
        let turn = ConversationTurn(runID: call.runID, items: [.userText("waiting for system consent")])
        let liveStore = makeLiveStore(conversationID: call.conversationID, turns: [turn])

        let rebuiltRuns = liveStore.consume(.approvalRequired(
            runID: call.runID,
            toolCallID: call.toolCallID
        ))
        let approvals = try await runtime.pendingToolApprovals(in: call.conversationID)
        liveStore.reconcilePendingToolApprovals(approvals)

        #expect(rebuiltRuns.isEmpty)
        #expect(approvals.isEmpty)
        #expect(liveStore.state.pendingToolApprovals.isEmpty)
        #expect(liveStore.state.timeline.turns == [turn])
        #expect(try environment.store.toolCall(id: call.toolCallID)?.state == .waitingForSystemPermissionConsent)
    }

    @Test("childCallDoesNotAcquireParentApprovalSubject")
    func childCallDoesNotAcquireParentApprovalSubject() async throws {
        let environment = try makeEnvironment()
        let conversationID = "parent-child-approval"
        let parentRunID = "parent-approval-run"
        _ = try environment.store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: conversationID,
                messageID: "parent-approval-message",
                runID: parentRunID,
                runState: .waitingForApproval
            )
        )

        let parentCallID = "parent-approval-call"
        let parentIntent = try preparedIntent(
            callID: parentCallID,
            argumentsJSON: "{}",
            disclosure: makeDisclosure(target: "Parent target", impact: "Parent impact")
        )
        try environment.store.createToolCall(
            Fixtures.toolCall(
                id: parentCallID,
                runID: parentRunID,
                action: parentIntent.toolID,
                state: .waitingForApproval,
                intent: try encodeIntent(parentIntent)
            )
        )

        var derivedChild = Fixtures.run(
            id: "child-approval-run",
            conversationID: conversationID,
            kind: .child,
            state: .waitingForApproval,
            parentRunID: parentRunID
        )
        derivedChild.activeSlot = PersistenceStore.activeSlot(for: derivedChild)
        let childRun = derivedChild
        try environment.store.database.write { db in try childRun.insert(db) }

        let childCallID = "child-approval-call"
        let childIntent = try preparedIntent(
            callID: childCallID,
            argumentsJSON: "{}",
            disclosure: makeDisclosure(target: "Child target", impact: "Child impact")
        )
        try environment.store.createToolCall(
            Fixtures.toolCall(
                id: childCallID,
                runID: childRun.id,
                action: childIntent.toolID,
                state: .waitingForApproval,
                intent: try encodeIntent(childIntent)
            )
        )

        let runtime = makeProjectionRuntime(for: environment)
        let approvals = try await runtime.pendingToolApprovals(in: conversationID)
        #expect(approvals.map(\.toolCallID) == [parentCallID])
        #expect(!approvals.contains { $0.toolCallID == childCallID })
        #expect(try environment.store.run(id: childRun.id)?.parentRunID == parentRunID)
        #expect(try environment.store.toolCall(id: childCallID)?.state == .waitingForApproval)
    }

    private struct Environment {
        var store: PersistenceStore
        var credentials: CredentialStore
        var instance: ProviderInstance
        var toolRegistry: ToolRegistry
        var sideEffectLedger: SideEffectLedger

        func reusing(store: PersistenceStore) -> Environment {
            Environment(
                store: store,
                credentials: credentials,
                instance: instance,
                toolRegistry: toolRegistry,
                sideEffectLedger: sideEffectLedger
            )
        }
    }

    private struct PendingApproval {
        var conversationID: String
        var runID: String
        var toolCallID: String
        var runtime: ConversationRuntime
        var eventRecorder: Stage2GateEventRecorder
        var providerLedger: I07ProviderLedger
    }

    private struct PendingPair {
        var first: PendingApproval
        var second: PendingApproval
    }

    private func makeEnvironment(
        conversationIDs: [String] = [],
        database: ZenDatabase? = nil
    ) throws -> Environment {
        let resolvedDatabase: ZenDatabase
        if let database {
            resolvedDatabase = database
        } else {
            resolvedDatabase = try ZenDatabase.inMemory()
        }
        let store = PersistenceStore(database: resolvedDatabase)
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let reference = CredentialReference(id: "tool-approval-test-credential")
        try credentials.provision(SecretValue("tool-approval-test-secret"), as: reference)
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "tool-approval-test-provider"),
            providerID: .deepSeek,
            displayName: "Tool approval test provider",
            baseURL: URL(string: "https://tool-approval.invalid"),
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)
        try store.database.write { db in
            for conversationID in conversationIDs {
                try Fixtures.conversation(id: conversationID).insert(db)
            }
        }
        let ledger = SideEffectLedger()
        let registry = try ToolRegistry(tools: [Stage2SideEffectTool(ledger: ledger)])
        return Environment(
            store: store,
            credentials: credentials,
            instance: instance,
            toolRegistry: registry,
            sideEffectLedger: ledger
        )
    }

    private func makeProjectionRuntime(for environment: Environment) -> ConversationRuntime {
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: environment.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming, .tools]
        )
        return ConversationRuntime(
            store: environment.store,
            provider: provider,
            credentials: environment.credentials,
            toolRegistry: environment.toolRegistry
        )
    }

    private func startPendingPair(
        in environment: Environment,
        firstConversationID: String = "approval-owner-a",
        secondConversationID: String = "approval-owner-b"
    ) async throws -> PendingPair {
        let first = try await startPendingApproval(in: environment, conversationID: firstConversationID)
        let second = try await startPendingApproval(in: environment, conversationID: secondConversationID)
        return PendingPair(first: first, second: second)
    }

    private func startPendingApproval(
        in environment: Environment,
        conversationID: String
    ) async throws -> PendingApproval {
        let providerLedger = I07ProviderLedger()
        let eventRecorder = Stage2GateEventRecorder()
        let provider = I07ScriptedProvider(
            ledger: providerLedger,
            instanceID: environment.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-\(conversationID)",
                        index: 0,
                        name: Self.toolID,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta(Self.continuationText),
                    .finish(.stop),
                ],
            ],
            store: environment.store,
            conversationID: conversationID
        )
        let runtime = ConversationRuntime(
            store: environment.store,
            provider: provider,
            credentials: environment.credentials,
            onEvent: { event in await eventRecorder.append(event) },
            toolRegistry: environment.toolRegistry
        )
        let runID = try await runtime.start(SendCommand(
            conversationID: conversationID,
            text: "perform the requested side effect",
            providerInstanceID: environment.instance.id,
            modelID: I05RuntimeTestFixtures.modelID,
            maxProviderSteps: 4,
            submissionID: "tool-approval-\(conversationID)"
        ))
        let toolCallID = await eventRecorder.waitForApproval()
        #expect(try environment.store.toolCall(id: toolCallID)?.state == .waitingForApproval)
        #expect(try environment.store.run(id: runID)?.state == .waitingForApproval)
        return PendingApproval(
            conversationID: conversationID,
            runID: runID,
            toolCallID: toolCallID,
            runtime: runtime,
            eventRecorder: eventRecorder,
            providerLedger: providerLedger
        )
    }

    private func stopIfActive(_ pending: PendingApproval, in store: PersistenceStore) async throws {
        guard let run = try store.run(id: pending.runID), !run.state.isTerminal else { return }
        try await pending.runtime.stop(runID: pending.runID)
        try await pending.runtime.waitForCompletion(runID: pending.runID)
    }

    private func makePersistedApproval(
        in environment: Environment,
        conversationID: String,
        runID: String,
        callID: String,
        callState: ToolCallState = .waitingForApproval
    ) throws -> ToolCallRecord {
        let intent = try preparedIntent(
            callID: callID,
            argumentsJSON: "{}",
            disclosure: makeDisclosure(target: "Target for \(callID)", impact: "Impact for \(callID)")
        )
        return try persistPendingCall(
            in: environment.store,
            conversationID: conversationID,
            runID: runID,
            callID: callID,
            intent: intent,
            callState: callState
        )
    }

    private func persistPendingCall(
        in store: PersistenceStore,
        conversationID: String,
        runID: String,
        callID: String,
        intent: ToolExecutionIntent,
        callState: ToolCallState = .waitingForApproval
    ) throws -> ToolCallRecord {
        _ = try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(
                conversationID: conversationID,
                messageID: "message-\(runID)",
                runID: runID,
                runState: .waitingForApproval
            )
        )
        let call = Fixtures.toolCall(
            id: callID,
            runID: runID,
            action: intent.toolID,
            state: callState,
            intent: try encodeIntent(intent)
        )
        try store.createToolCall(call)
        return call
    }

    private func preparedIntent(
        by tool: I07RecordingTool? = nil,
        callID: String,
        argumentsJSON: String,
        disclosure: ToolApprovalDisclosure
    ) throws -> ToolExecutionIntent {
        let testTool = tool ?? I07RecordingTool(
            id: "frozen-intent-probe",
            approvalRequirement: .required,
            ledger: I07ToolLedger()
        )
        var intent = try testTool.prepare(callID: callID, argumentsJSON: argumentsJSON)
        intent.approvalDisclosure = disclosure
        return intent
    }

    private func makeDisclosure(target: String, impact: String) -> ToolApprovalDisclosure {
        ToolApprovalDisclosure(
            toolDisplayName: "Frozen Intent Probe",
            action: "Replace document",
            targetDescription: target,
            keyImpact: impact
        )
    }

    private func encodeIntent(_ intent: ToolExecutionIntent) throws -> String {
        String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
    }

    private func decodeIntent(from call: ToolCallRecord) throws -> ToolExecutionIntent {
        let json = try #require(call.executionIntent)
        return try JSONDecoder().decode(ToolExecutionIntent.self, from: Data(json.utf8))
    }

    private func renderedDisclosureText(_ approval: ToolApprovalProjection) -> String {
        [approval.toolDisplayName, approval.action, approval.targetDescription, approval.keyImpact]
            .joined(separator: "\n")
    }

    private func makeLiveStore(
        conversationID: String,
        turns: [ConversationTurn] = []
    ) -> LiveConversationStore {
        LiveConversationStore(
            projection: ConversationTimelineProjection(conversationID: conversationID, turns: turns),
            coalescer: StreamingCoalescer(interval: .milliseconds(10))
        )
    }

    private func assistantText(for runID: String, in store: PersistenceStore) throws -> String {
        guard let run = try store.run(id: runID), let responseMessageID = run.responseMessageID else {
            Issue.record("the completed Parent Run must reference its assistant response")
            return ""
        }
        let parts = try store.parts(ofMessage: responseMessageID)
        return try parts
            .filter { $0.kind == .text }
            .compactMap { try store.text(ofPart: $0.id) }
            .joined()
    }

    private func assertApprovalButtonAndTimelineHandoffs() {
        guard let sources = sourceFiles() else { return }
        let card = sources["App/Conversation/ToolApprovalCardView.swift"] ?? ""
        let timeline = sources["App/Conversation/ConversationTimelineView.swift"] ?? ""
        guard let decisionButtons = closureBody(in: card, after: "ForEach(ToolApprovalDecision.allCases") else {
            Issue.record("could not locate the ToolApprovalCardView decision button action")
            return
        }
        guard let timelineHandoff = closureBody(in: timeline, after: "ToolApprovalCardView(approval:") else {
            Issue.record("could not locate the ConversationTimelineView approval handoff closure")
            return
        }

        #expect(decisionButtons.contains("Button(decision.title)"))
        #expect(decisionButtons.contains("let request = approval.request(for: decision)"))
        #expect(decisionButtons.contains("onDecision(request)"))
        #expect(timelineHandoff.range(
            of: #"resolveToolApproval\(\s*request\s*\)"#,
            options: .regularExpression
        ) != nil)
    }

    private func closureBody(in source: String, after marker: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var body = ""
        for character in source[openingBrace...] {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
        }
        return nil
    }

    private func sourceFiles() -> [String: String]? {
        let allowedSourcePaths = [
            "App/Conversation/ToolApprovalCardView.swift",
            "App/Conversation/ConversationTimelineView.swift",
        ]
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root from the test source path")
            return nil
        }

        var sources: [String: String] = [:]
        for path in allowedSourcePaths {
            let url = root.appending(path: path)
            guard let data = try? Data(contentsOf: url) else {
                Issue.record("could not read approval source \(path)")
                return nil
            }
            sources[path] = String(decoding: data, as: UTF8.self)
        }
        return sources
    }

    private func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != directory.deletingLastPathComponent().path {
            let app = directory.appending(path: "App")
            let tests = directory.appending(path: "Tests")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: app.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               fileManager.fileExists(atPath: tests.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
