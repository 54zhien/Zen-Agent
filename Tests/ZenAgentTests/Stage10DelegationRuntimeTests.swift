import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 10 delegation runtime")
struct Stage10DelegationRuntimeTests {

    @Test("an enabled Parent delegates once and resumes with the persisted Child result")
    func parentDelegatesAndContinuesFromChildResult() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let childTask = "Summarize the requested change."
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "delegation-provider-call",
                        index: 0,
                        name: "subagent",
                        argumentsJSON: #"{"task":"Summarize the requested change."}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([
                    .textDelta("child answer"),
                    .usage(ProviderTokenUsage(promptTokens: 31, completionTokens: 4, totalTokens: 35)),
                    .finish(.stop),
                ]),
                .events([.textDelta("parent answer"), .finish(.stop)]),
            ]
        )
        let events = Stage10DelegationEventLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { await events.append($0) }
        )
        try fixture.store.setDelegationEnabled(true)

        var command = I05RuntimeTestFixtures.command(modelID: Stage2GateFixture.modelID)
        command.text = "Review this change."
        command.conversationID = I05RuntimeTestFixtures.conversationID
        let parentRunID = try await runtime.start(command)
        let parentToolCallID = await events.waitForApproval()
        try await runtime.approve(toolCallID: parentToolCallID)
        try await runtime.waitForCompletion(runID: parentRunID)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let parentSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(parent.executionSnapshot)
        )
        #expect(parent.state == .completed)
        #expect(parentSnapshot.delegation?.enabled == true)
        #expect(parentSnapshot.delegation?.maxDepth == 1)
        #expect(parentSnapshot.delegation?.maxConcurrentChildren == 1)
        #expect(parentSnapshot.delegation?.modelPolicy == .followParent)
        #expect(parentSnapshot.delegation?.environmentInheritance == DelegationEnvironmentInheritance.none)
        #expect(parentSnapshot.exposedTools.contains { $0.toolID == "subagent" })

        let runs = try fixture.store.runs(inConversation: command.conversationID)
        let child = try #require(runs.first { $0.kind == .child })
        #expect(child.parentRunID == parentRunID)
        #expect(child.requestConfigSeed == parent.requestConfigSeed)
        #expect(child.state == .completed)
        #expect(parent.stopRequestedAt == nil)
        #expect(child.stopRequestedAt == nil)
        let childSnapshot = try ExecutionSnapshotCodec.decode(
            try #require(child.executionSnapshot)
        )
        #expect(!childSnapshot.modelCapabilities.contains(.tools))
        #expect(childSnapshot.exposedTools.isEmpty)
        #expect(childSnapshot.prompt.memoryReferences.isEmpty)
        #expect(childSnapshot.prompt.skillReferences.isEmpty)
        #expect(childSnapshot.delegation == nil)

        #expect(child.triggerMessageID == nil)
        let childResponseID = try #require(child.responseMessageID)
        let childAnswer = try fixture.store.parts(ofMessage: childResponseID)
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(childAnswer == "child answer")

        let parentCalls = try fixture.store.toolCalls(inRun: parentRunID)
        let delegationCall = try #require(parentCalls.first)
        #expect(delegationCall.state == .succeeded)
        let result = try #require(try fixture.store.toolResult(toolCallID: delegationCall.id))
        #expect(result.payload == "child answer")

        let reportData = try #require(try fixture.store.latestParentChildMeasurementJSON(
            generatedAt: Date(timeIntervalSince1970: 123)
        ))
        let report = try #require(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        let parentReport = try #require(report["parent"] as? [String: Any])
        #expect(parentReport["runID"] as? String == parentRunID)
        #expect(parentReport["providerID"] as? String == ProviderID.deepSeek.rawValue)
        #expect(parentReport["modelID"] as? String == Stage2GateFixture.modelID.rawValue)
        let parentSteps = try #require(parentReport["providerSteps"] as? [[String: Any]])
        #expect(parentSteps[0]["reportedPromptTokens"] is NSNull)
        let childReports = try #require(report["children"] as? [[String: Any]])
        let childReport = try #require(childReports.first)
        #expect(childReport["runID"] as? String == child.id)
        #expect(childReport["providerID"] as? String == ProviderID.deepSeek.rawValue)
        #expect(childReport["modelID"] as? String == Stage2GateFixture.modelID.rawValue)
        let childSteps = try #require(childReport["providerSteps"] as? [[String: Any]])
        #expect(childSteps[0]["reportedPromptTokens"] as? Int == 31)
        #expect(childSteps[0]["reportedCompletionTokens"] as? Int == 4)
        #expect(childSteps[0]["reportedTotalTokens"] as? Int == 35)
        #expect(childReport["terminalAt"] as? String != nil)
        let reportText = String(decoding: reportData, as: UTF8.self)
        #expect(!reportText.contains(childTask))
        #expect(!reportText.contains("child answer"))
        #expect(!reportText.contains("parent answer"))

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }
        #expect(requests[0].tools.contains { $0.name == "subagent" })
        #expect(requests[1].tools.isEmpty)
        #expect(requests[1].messages.compactMap { message -> String? in
            guard case .user(let text) = message else { return nil }
            return text
        } == [childTask])
        #expect(requests[2].messages.contains { message in
            guard case .toolResult(_, let content) = message else { return false }
            return content == "child answer"
        })

        let timeline = try ConversationTimelineLoader.load(
            conversationID: command.conversationID,
            from: fixture.store
        )
        #expect(timeline.turns.map(\.runID) == [parentRunID])
    }

    @Test("two delegated Children run together and return to their original calls in batch order")
    func twoDelegatedChildrenSettleInProviderBatchOrder() async throws {
        let scenario = try await makeDualChildScenario(mode: .returnResults)
        _ = await scenario.parentEvents.waitForApproval(at: 0)

        let firstChildApproval = await scenario.childEvents.waitForApproval(at: 0)
        let secondChildApproval = await scenario.childEvents.waitForApproval(
            onRunDifferentFrom: firstChildApproval.runID
        )
        #expect(firstChildApproval.runID != secondChildApproval.runID)
        let children = try scenario.store.activeDelegatedChildRunIDs(parentRunID: scenario.parentRunID)
        #expect(children.count == 2)
        guard children.count == 2 else {
            try await scenario.runtime.stop(runID: scenario.parentRunID)
            await scenario.parentEvents.waitForRunState(runID: scenario.parentRunID, state: .cancelled)
            try await scenario.completion.value
            return
        }

        let providerBatchCalls = try scenario.store.toolCalls(inRun: scenario.parentRunID)
            .filter { $0.action == SubagentDelegationTool.toolID }
        let sequencedParentCalls: [(sequence: Int, call: ToolCallRecord)] = try providerBatchCalls.map { call in
            (sequence: try #require(call.batchSequence), call: call)
        }
        let parentCalls = sequencedParentCalls.sorted { $0.sequence < $1.sequence }.map { $0.call }
        let parentProviderCallIDs = try parentCalls.map { try #require($0.providerCallID) }
        #expect(parentProviderCallIDs == ["provider-delegation-alpha", "provider-delegation-beta"])
        let alphaParentCall = try #require(parentCalls.first { $0.providerCallID == "provider-delegation-alpha" })
        let betaParentCall = try #require(parentCalls.first { $0.providerCallID == "provider-delegation-beta" })
        let alphaChildID = try #require(try scenario.store.delegatedChildRunID(parentToolCallID: alphaParentCall.id))
        let betaChildID = try #require(try scenario.store.delegatedChildRunID(parentToolCallID: betaParentCall.id))
        #expect(Set(children) == Set([alphaChildID, betaChildID]))

        let alphaApproval = await scenario.childEvents.waitForApproval(runID: alphaChildID)
        let betaApproval = await scenario.childEvents.waitForApproval(runID: betaChildID)
        #expect(Set([firstChildApproval.runID, secondChildApproval.runID]) == Set([alphaChildID, betaChildID]))

        try await scenario.runtime.approveToolCall(toolCallID: betaApproval.toolCallID, scope: .once)
        await scenario.childEvents.waitForRunState(runID: betaChildID, state: .completed)
        try await scenario.runtime.approveToolCall(toolCallID: alphaApproval.toolCallID, scope: .once)
        await scenario.childEvents.waitForRunState(runID: alphaChildID, state: .completed)
        await scenario.parentEvents.waitForRunState(runID: scenario.parentRunID, state: .completed)
        try await scenario.completion.value

        #expect(try scenario.store.toolCall(id: alphaParentCall.id)?.state == .succeeded)
        #expect(try scenario.store.toolCall(id: betaParentCall.id)?.state == .succeeded)
        #expect(try scenario.store.toolResult(toolCallID: alphaParentCall.id)?.payload == "alpha child answer")
        #expect(try scenario.store.toolResult(toolCallID: betaParentCall.id)?.payload == "beta child answer")

        let requests = await scenario.providerLedger.requestsSnapshot()
        let parentContinuation = try #require(requests.last)
        let returnedCalls = parentContinuation.messages.compactMap { message -> (String, String)? in
            guard case .toolResult(let callID, let content) = message else { return nil }
            return (callID, content)
        }
        #expect(returnedCalls.suffix(2).map(\.0) == ["provider-delegation-alpha", "provider-delegation-beta"])
        #expect(returnedCalls.suffix(2).map(\.1) == ["alpha child answer", "beta child answer"])
    }

    @Test("Parent Stop cancels both active Children and keeps their known Child tool results")
    func parentStopCancelsTwoChildrenWithoutLosingKnownToolResults() async throws {
        let scenario = try await makeDualChildScenario(mode: .stopWithKnownResults)
        _ = await scenario.parentEvents.waitForApproval(at: 0)

        let firstChildApproval = await scenario.childEvents.waitForApproval(at: 0)
        let secondChildApproval = await scenario.childEvents.waitForApproval(
            onRunDifferentFrom: firstChildApproval.runID
        )
        #expect(firstChildApproval.runID != secondChildApproval.runID)
        let children = try scenario.store.activeDelegatedChildRunIDs(parentRunID: scenario.parentRunID)
        #expect(children.count == 2)
        guard children.count == 2 else {
            try await scenario.runtime.stop(runID: scenario.parentRunID)
            await scenario.parentEvents.waitForRunState(runID: scenario.parentRunID, state: .cancelled)
            try await scenario.completion.value
            return
        }

        let parentCalls = try scenario.store.toolCalls(inRun: scenario.parentRunID)
            .filter { $0.action == SubagentDelegationTool.toolID }
        let childIDs = try parentCalls.map { try #require(try scenario.store.delegatedChildRunID(parentToolCallID: $0.id)) }
        for childID in childIDs {
            let knownCall = try #require(try scenario.store.toolCalls(inRun: childID).first {
                $0.action == Stage10DualChildProvider.knownToolID && $0.state == .succeeded
            })
            #expect(try scenario.store.toolResult(toolCallID: knownCall.id)?.payload.contains("known result") == true)
            _ = await scenario.childEvents.waitForApproval(runID: childID)
        }

        try await scenario.runtime.stop(runID: scenario.parentRunID)
        await scenario.parentEvents.waitForRunState(runID: scenario.parentRunID, state: .cancelled)
        for childID in childIDs {
            await scenario.childEvents.waitForRunState(runID: childID, state: .cancelled)
            #expect(try scenario.store.run(id: childID)?.state == .cancelled)
            let knownCall = try #require(try scenario.store.toolCalls(inRun: childID).first {
                $0.action == Stage10DualChildProvider.knownToolID
            })
            #expect(knownCall.state == .succeeded)
            #expect(try scenario.store.toolResult(toolCallID: knownCall.id)?.payload.contains("known result") == true)
        }
        #expect(try scenario.store.run(id: scenario.parentRunID)?.state == .cancelled)
        try await scenario.completion.value
    }

    @Test("taskless Child Stop settles only that Child and keeps its persisted tool result")
    func tasklessChildStopKeepsSiblingAndKnownResult() throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-taskless-stop-parent"
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [])
        let configuration = try fixture.store.setDelegationEnabled(true)
        let prompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
            zenCore: PromptTemplateCatalog.currentZenCoreRevision,
            providerAdapterInstructions: provider.adapterPromptInstructions
        )
        let validationPolicy = try JSONDecoder().decode(
            DelegationExecutionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: [
                "revision": configuration.revision,
                "enabled": true,
                "maxDepth": 1,
                "maxConcurrentChildren": DelegationExecutionSnapshot.hiddenDualChildProbeLimit,
                "modelPolicy": DelegationModelPolicy.followParent.rawValue,
                "environmentInheritance": DelegationEnvironmentInheritance.none.rawValue,
            ], options: [.sortedKeys])
        )
        let parentSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [Self.exposure(SubagentDelegationTool.toolDescriptor)],
            maxProviderSteps: 4,
            delegation: validationPolicy
        )
        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-taskless-stop-message",
            runID: parentRunID,
            runState: .executingTools
        )
        commit.run.requestConfigSeed = try provider.makeRequestConfigSeed(
            instance: fixture.instance,
            modelID: Stage2GateFixture.modelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: I05RuntimeTestFixtures.credentialReference,
                generation: 1
            )
        )
        commit.run.executionSnapshot = try ExecutionSnapshotCodec.encode(parentSnapshot)
        try fixture.store.commitUserTurnAndCreateParentRun(commit)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let setupRuntime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: setupRuntime,
            project: { _ in }
        )
        let executor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let childSnapshot = try ExecutionSnapshotCodec.encode(RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: 4
        ))
        let children = [
            ("stage10-taskless-child-alpha", "stage10-taskless-parent-call-alpha", "alpha child task"),
            ("stage10-taskless-child-beta", "stage10-taskless-parent-call-beta", "beta child task"),
        ]
        for (sequence, (childID, parentCallID, task)) in children.enumerated() {
            let intent = try executor.prepare(
                callID: parentCallID,
                argumentsJSON: String(decoding: try JSONEncoder().encode(["task": task]), as: UTF8.self),
                context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
            )
            var parentCall = Fixtures.toolCall(
                id: parentCallID,
                runID: parentRunID,
                action: SubagentDelegationTool.toolID,
                state: .dispatched,
                intent: String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
            )
            parentCall.providerCallID = "provider-taskless-\(sequence)"
            parentCall.batchID = "batch-stage10-taskless-stop"
            parentCall.batchSequence = sequence
            try fixture.store.createToolCall(parentCall)

            var child = Fixtures.run(
                id: childID,
                conversationID: parent.conversationID,
                kind: .child,
                state: .preparing,
                parentRunID: parentRunID
            )
            child.requestConfigSeed = parent.requestConfigSeed
            child.executionSnapshot = childSnapshot
            try fixture.store.createDelegatedChildRun(parentToolCallID: parentCallID, childRun: child)
        }

        let knownCallID = "stage10-taskless-child-known-result"
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: knownCallID,
            runID: children[0].0,
            action: "stage10-known-child-tool",
            state: .succeeded
        ))
        try fixture.store.database.write { db in
            try ToolResultRecord(
                toolCallID: knownCallID,
                payload: "known child result",
                createdAt: Date()
            ).insert(db)
        }
        try fixture.store.transitionRun(
            id: parentRunID,
            expectedState: .executingTools,
            to: .stopping
        )

        #expect(try fixture.store.cancelTasklessDelegatedChild(
            parentRunID: parentRunID,
            childRunID: children[0].0
        ) == [children[0].0])
        #expect(try fixture.store.run(id: children[0].0)?.state == .cancelled)
        #expect(try fixture.store.run(id: children[1].0)?.state == .preparing)
        #expect(try fixture.store.activeDelegatedChildRunIDs(parentRunID: parentRunID) == [children[1].0])
        #expect(try fixture.store.toolCall(id: knownCallID)?.state == .succeeded)
        #expect(try fixture.store.toolResult(toolCallID: knownCallID)?.payload == "known child result")
    }

    @Test("Child tool approval is projected to its owning Conversation and resumes the same Child call")
    func childToolApprovalResumesSameCall() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let toolID = "stage10-child-recording-tool"
        let toolLedger = I07ToolLedger()
        let tool = I07RecordingTool(id: toolID, approvalRequirement: .required, ledger: toolLedger)
        let registry = try ToolRegistry(tools: [tool])
        try fixture.store.setMemoryEnabled(true)
        let parentMemory = try fixture.store.saveMemory(content: "Parentonly memory marker.")
        let childMemory = try fixture.store.saveMemory(content: "Childalpha memory marker.")
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        let appMode = try environment.savePlain(key: "APP_MODE", value: "sandbox")
        let skillRuntime = SkillRuntime(store: fixture.store, credentials: fixture.credentials, registry: registry)
        let childSkill = try skillRuntime.saveUser(definition: SkillDefinition(
            name: "Child Alpha",
            summary: "Child task guidance.",
            instructions: "Apply ${APP_MODE} mode.",
            requiredTools: [toolID],
            environmentKeys: ["APP_MODE"],
            triggerTerms: ["childalpha"]
        ))
        let parentOnlySkill = try skillRuntime.saveUser(definition: SkillDefinition(
            name: "Parent Only",
            summary: "Only relevant to the Parent request.",
            instructions: "Parent-only workflow.",
            environmentKeys: ["APP_MODE"],
            triggerTerms: ["parentonly"]
        ))
        try await skillRuntime.setEnabled(id: childSkill.id, enabled: true)
        try await skillRuntime.setEnabled(id: parentOnlySkill.id, enabled: true)
        let events = Stage10ApprovalLedger()
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: providerLedger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "parent-delegation-call",
                        index: 0,
                        name: SubagentDelegationTool.toolID,
                        argumentsJSON: #"{"task":"Use childalpha to perform the task.","environmentKeys":["APP_MODE"]}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([
                    .toolCall(ProviderToolCall(
                        id: "child-recording-call",
                        index: 0,
                        name: toolID,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("child answer"), .finish(.stop)]),
                .events([.textDelta("parent answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { await events.append($0) },
            toolRegistry: registry
        )
        try fixture.store.setDelegationEnabled(true)

        var command = I05RuntimeTestFixtures.command(
            text: "Use parentonly and childalpha context before delegating.",
            modelID: Stage2GateFixture.modelID
        )
        command.selectedSkillIDs = [childSkill.id, parentOnlySkill.id]
        let parentRunID = try await runtime.start(command)
        let parentCallID = await events.waitForApproval(at: 0).toolCallID
        let parentIntent = try ToolIntentCodec.decodeForDisplay(
            try #require(try fixture.store.toolCall(id: parentCallID)?.executionIntent)
        )
        #expect(parentIntent.approvalDisclosure?.keyImpact.contains("APP_MODE") == true)
        try await runtime.approve(toolCallID: parentCallID, scope: .once)

        let childApproval = await events.waitForApproval(at: 1)
        let child = try #require(try fixture.store.run(id: childApproval.runID))
        let childSnapshot = try ExecutionSnapshotCodec.decode(try #require(child.executionSnapshot))
        #expect(child.kind == .child)
        #expect(child.parentRunID == parentRunID)
        #expect(childSnapshot.exposedTools.map(\.toolID) == [toolID])
        #expect(childSnapshot.prompt.memoryReferences == [childMemory.reference])
        #expect(childSnapshot.prompt.skillReferences.map(\.skillID) == [childSkill.id])
        #expect(childSnapshot.prompt.skillReferences.first?.environmentReferences == [appMode.reference])
        #expect(try ExecutionSnapshotCodec.decode(try #require(
            try fixture.store.run(id: parentRunID)?.executionSnapshot
        )).prompt.memoryReferences.contains(parentMemory.reference))
        #expect(try ExecutionSnapshotCodec.decode(try #require(
            try fixture.store.run(id: parentRunID)?.executionSnapshot
        )).prompt.skillReferences.map(\.skillID).contains(parentOnlySkill.id))

        let requests = await providerLedger.requestsSnapshot()
        guard requests.count >= 2 else {
            Issue.record("the Child Provider request was not recorded")
            return
        }
        let childUserContent = requests[1].messages.compactMap { message -> String? in
            guard case .user(let content) = message else { return nil }
            return content
        }.joined(separator: "\n")
        #expect(childUserContent.contains("Childalpha memory marker."))
        #expect(!childUserContent.contains("Parentonly memory marker."))
        #expect(childUserContent.contains("Workflow: Child Alpha"))
        #expect(!childUserContent.contains("Workflow: Parent Only"))
        #expect(childUserContent.contains("Apply sandbox mode."))

        let cards = try await runtime.pendingToolApprovals(in: child.conversationID)
        let card = try #require(cards.first { $0.toolCallID == childApproval.toolCallID })
        #expect(card.source == .subagent)
        #expect(card.authorizationOwnerDescription == "Subagent · 本次 Child Run")
        #expect(card.availableDecisions == [.approveOnce, .rejectOnce])

        try await runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await runtime.waitForCompletion(runID: parentRunID)

        #expect(try fixture.store.toolCall(id: childApproval.toolCallID)?.state == .succeeded)
        #expect(try fixture.store.toolCall(id: parentCallID)?.state == .succeeded)
        #expect(await toolLedger.snapshot().map(\.idempotencyKey) == [childApproval.toolCallID])
        #expect(try fixture.store.toolResult(toolCallID: parentCallID)?.payload.contains("child answer") == true)
    }

    @Test("cold Parent recovery resumes the original Child approval and delegated call")
    func coldApprovalResumesOriginalChildCall() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [
            .events([.textDelta("child continuation"), .finish(.stop)]),
            .events([.textDelta("parent continuation"), .finish(.stop)]),
        ])

        let report = try await scenario.runtime.reconcileColdStartRuns()
        #expect(report.continuedRunIDs == [scenario.parentRunID])
        let approval = await scenario.events.waitForApproval(at: 0)
        #expect(approval.runID == scenario.childRunID)
        #expect(approval.toolCallID == scenario.childToolCallID)

        let cards = try await scenario.runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID)
        let card = try #require(cards.first { $0.toolCallID == scenario.childToolCallID })
        #expect(card.source == .subagent)
        #expect(card.authorizationOwnerDescription == "Subagent · 本次 Child Run")
        #expect(card.availableDecisions == [.approveOnce, .rejectOnce])
        try await scenario.runtime.resolveToolApproval(card.request(for: .approveOnce))
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        #expect(try scenario.store.run(id: scenario.childRunID)?.state == .completed)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .succeeded)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .succeeded)
        #expect(await scenario.toolLedger.snapshot().map(\.idempotencyKey) == [scenario.childToolCallID])
        #expect(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID)?.payload.contains("child continuation") == true)

        let requests = await scenario.providerLedger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        #expect(requests[0].messages.contains { message in
            guard case .toolResult(let callID, _) = message else { return false }
            return callID == "child-provider-call"
        })
        #expect(requests[1].messages.contains { message in
            guard case .toolResult(let callID, let content) = message else { return false }
            return callID == "parent-provider-call" && content.contains("child continuation")
        })
    }

    @Test("cold Child approval rejection continues the same Child and Parent calls")
    func coldApprovalRejectionContinuesOriginalCalls() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [
            .events([.textDelta("child handled rejection"), .finish(.stop)]),
            .events([.textDelta("parent continuation"), .finish(.stop)]),
        ])

        _ = try await scenario.runtime.reconcileColdStartRuns()
        let approval = await scenario.events.waitForApproval(at: 0)
        let cards = try await scenario.runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID)
        let card = try #require(cards.first { $0.toolCallID == scenario.childToolCallID })
        #expect(approval.toolCallID == card.toolCallID)
        try await scenario.runtime.resolveToolApproval(card.request(for: .rejectOnce))
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        #expect(try scenario.store.run(id: scenario.childRunID)?.state == .completed)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .rejected)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .succeeded)
        #expect(await scenario.toolLedger.snapshot().isEmpty)
        #expect(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID)?.payload.contains("child handled rejection") == true)
    }

    @Test("stopping a recovered Child approval cancels Child and preserves its result on the Parent call")
    func stopDuringColdChildApprovalSettlesBothRuns() async throws {
        let scenario = try makeColdApprovalScenario(scripts: [])

        _ = try await scenario.runtime.reconcileColdStartRuns()
        let approval = await scenario.events.waitForApproval(at: 0)
        #expect(approval.runID == scenario.childRunID)
        try await scenario.runtime.stop(runID: scenario.parentRunID)
        try await scenario.runtime.waitForCompletion(runID: scenario.parentRunID)

        let parent = try #require(try scenario.store.run(id: scenario.parentRunID))
        let child = try #require(try scenario.store.run(id: scenario.childRunID))
        #expect(parent.state == .cancelled)
        #expect(child.state == .cancelled)
        #expect(parent.stopRequestedAt != nil)
        #expect(child.stopRequestedAt != nil)
        #expect(try scenario.store.toolCall(id: scenario.childToolCallID)?.state == .notExecuted)
        #expect(try scenario.store.toolCall(id: scenario.parentToolCallID)?.state == .failed)
        let result = try #require(try scenario.store.toolResult(toolCallID: scenario.parentToolCallID))
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        #expect(result.payload.contains("cancelledByUser"))
        #expect(await scenario.providerLedger.requestsSnapshot().isEmpty)
    }

    private func makeColdApprovalScenario(
        scripts: [Stage2ProviderScript]
    ) throws -> Stage10ColdApprovalScenario {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-cold-parent"
        let childRunID = "stage10-cold-child"
        let parentToolCallID = "stage10-cold-parent-delegation"
        let childToolCallID = "stage10-cold-child-tool-call"
        let childToolID = "stage10-cold-child-tool"
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: providerLedger, scripts: scripts)
        let toolLedger = I07ToolLedger()
        let childTool = I07RecordingTool(
            id: childToolID,
            approvalRequirement: .required,
            ledger: toolLedger
        )
        let registry = try ToolRegistry(tools: [childTool])
        let configuration = try fixture.store.setDelegationEnabled(true)
        let parentPrompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
            zenCore: PromptTemplateCatalog.currentZenCoreRevision,
            providerAdapterInstructions: provider.adapterPromptInstructions
        )
        let parentSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: parentPrompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [
                Self.exposure(childTool.descriptor),
                Self.exposure(SubagentDelegationTool.toolDescriptor),
            ],
            maxProviderSteps: 4,
            delegation: DelegationExecutionSnapshot(configuration: configuration)
        )
        let childSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: parentPrompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [Self.exposure(childTool.descriptor)],
            maxProviderSteps: 4,
            delegation: nil
        )

        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-cold-trigger",
            runID: parentRunID
        )
        commit.run.requestConfigSeed = try provider.makeRequestConfigSeed(
            instance: fixture.instance,
            modelID: Stage2GateFixture.modelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: I05RuntimeTestFixtures.credentialReference,
                generation: 1
            )
        )
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        try fixture.store.completeExecutionSnapshot(
            runID: parentRunID,
            encodedSnapshot: ExecutionSnapshotCodec.encode(parentSnapshot)
        )
        for (current, next) in zip(
            [RunState.preparing, .requestingModel, .streaming, .toolRequested],
            [RunState.requestingModel, .streaming, .toolRequested, .executingTools]
        ) {
            try fixture.store.transitionRun(id: parentRunID, expectedState: current, to: next)
        }

        let setupAgent = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let setupDelegation = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: setupAgent,
            project: { _ in }
        )
        let parentExecutor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: setupDelegation
        )
        let parentIntent = try parentExecutor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Summarize the requested change."}"#,
            context: ToolPreparationContext(
                requestConfigSeed: try #require(try fixture.store.run(id: parentRunID)?.requestConfigSeed)
            )
        )
        let encodedParentIntent = String(
            decoding: try JSONEncoder().encode(parentIntent),
            as: UTF8.self
        )
        var parentCall = Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .dispatched,
            intent: encodedParentIntent
        )
        parentCall.providerCallID = "parent-provider-call"
        parentCall.batchID = "batch-\(parentRunID)-0-1"
        parentCall.batchSequence = 0
        try fixture.store.createToolCall(parentCall)
        let parentProviderCall = ProviderToolCall(
            id: "parent-provider-call",
            index: 0,
            name: SubagentDelegationTool.toolID,
            argumentsJSON: #"{"task":"Summarize the requested change."}"#
        )
        let parentStep = Fixtures.step(stepID: "step-\(parentRunID)-0", runID: parentRunID)
        try fixture.store.recordStep(parentStep)
        try fixture.store.recordProtocolResponse(
            String(decoding: try JSONEncoder().encode(ToolCallProtocolTranscript(
                assistantContent: nil,
                calls: [parentProviderCall]
            )), as: UTF8.self),
            for: parentStep
        )

        var childRun = Fixtures.run(
            id: childRunID,
            conversationID: I05RuntimeTestFixtures.conversationID,
            kind: .child,
            state: .preparing,
            parentRunID: parentRunID
        )
        childRun.requestConfigSeed = try #require(try fixture.store.run(id: parentRunID)?.requestConfigSeed)
        childRun.executionSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        try fixture.store.createDelegatedChildRun(
            parentToolCallID: parentToolCallID,
            childRun: childRun
        )
        for (current, next) in zip(
            [RunState.preparing, .requestingModel, .streaming, .toolRequested, .executingTools],
            [RunState.requestingModel, .streaming, .toolRequested, .executingTools, .waitingForApproval]
        ) {
            try fixture.store.transitionRun(id: childRunID, expectedState: current, to: next)
        }

        let childIntent = try childTool.prepare(callID: childToolCallID, argumentsJSON: "{}")
        var childCall = Fixtures.toolCall(
            id: childToolCallID,
            runID: childRunID,
            action: childToolID,
            state: .waitingForApproval,
            intent: String(decoding: try JSONEncoder().encode(childIntent), as: UTF8.self)
        )
        childCall.providerCallID = "child-provider-call"
        childCall.batchID = "batch-\(childRunID)-0-1"
        childCall.batchSequence = 0
        try fixture.store.createToolCall(childCall)
        let childProviderCall = ProviderToolCall(
            id: "child-provider-call",
            index: 0,
            name: childToolID,
            argumentsJSON: "{}"
        )
        let childStep = Fixtures.step(stepID: "step-\(childRunID)-0", runID: childRunID)
        try fixture.store.recordStep(childStep)
        try fixture.store.recordProtocolResponse(
            String(decoding: try JSONEncoder().encode(ToolCallProtocolTranscript(
                assistantContent: nil,
                calls: [childProviderCall]
            )), as: UTF8.self),
            for: childStep
        )
        try fixture.store.transitionRun(
            id: parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .resume
        )

        let events = Stage10ApprovalLedger()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { await events.append($0) },
            toolRegistry: registry
        )
        return Stage10ColdApprovalScenario(
            store: fixture.store,
            runtime: runtime,
            events: events,
            providerLedger: providerLedger,
            toolLedger: toolLedger,
            parentRunID: parentRunID,
            childRunID: childRunID,
            parentToolCallID: parentToolCallID,
            childToolCallID: childToolCallID
        )
    }

    private func makeDualChildScenario(
        mode: Stage10DualChildProviderMode
    ) async throws -> Stage10DualChildScenario {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-dual-child-parent-\(UUID().uuidString)"
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage10DualChildProvider(ledger: providerLedger, mode: mode)
        let toolLedger = I07ToolLedger()
        let knownTool = I07RecordingTool(
            id: Stage10DualChildProvider.knownToolID,
            approvalRequirement: .notRequired,
            ledger: toolLedger
        )
        let holdTool = I07RecordingTool(
            id: Stage10DualChildProvider.holdToolID,
            approvalRequirement: .required,
            ledger: toolLedger
        )
        let baseToolRuntime = ToolRuntime(
            store: fixture.store,
            registry: .empty,
            credentials: fixture.credentials
        )
        let runtime = AgentRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRuntime: baseToolRuntime
        )
        let parentEvents = Stage10ApprovalLedger()
        let childEvents = Stage10ApprovalLedger()
        let projector = Stage10DualChildMessageProjector(store: fixture.store)
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: runtime,
            project: { event in
                try await projector.apply(event)
                await childEvents.append(event)
            }
        )
        let subagent = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let registry = try ToolRegistry(tools: [subagent, knownTool, holdTool])
        if mode == .stopWithKnownResults {
            try Fixtures.allowAutomaticToolPolicies(in: fixture.store, registry: registry)
        }
        await runtime.bindToolRegistry(
            ToolRuntimeRegistryContext(registry: registry),
            forRunID: parentRunID
        )

        let seed = try provider.makeRequestConfigSeed(
            instance: fixture.instance,
            modelID: Stage2GateFixture.modelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: I05RuntimeTestFixtures.credentialReference,
                generation: 1
            )
        )
        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-dual-child-user-\(UUID().uuidString)",
            runID: parentRunID
        )
        commit.run.requestConfigSeed = seed
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        let configuration = try fixture.store.setDelegationEnabled(true)
        let validationPolicyData = try JSONSerialization.data(withJSONObject: [
            "revision": configuration.revision,
            "enabled": configuration.enabled,
            "maxDepth": 1,
            "maxConcurrentChildren": 2,
            "modelPolicy": DelegationModelPolicy.followParent.rawValue,
            "environmentInheritance": DelegationEnvironmentInheritance.none.rawValue,
        ], options: [.sortedKeys])
        let delegation = try JSONDecoder().decode(
            DelegationExecutionSnapshot.self,
            from: validationPolicyData
        )
        let snapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                providerAdapterInstructions: provider.adapterPromptInstructions
            ),
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: registry.descriptors.map(Self.exposure),
            maxProviderSteps: 4,
            delegation: delegation
        )
        try fixture.store.completeExecutionSnapshot(
            runID: parentRunID,
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )

        let toolDefinitions = snapshot.exposedTools.map {
            ProviderToolDefinition(name: $0.toolID, description: $0.description, parameters: $0.inputSchema)
        }
        let stream = await runtime.advance(
            runID: parentRunID,
            request: ProviderChatRequest(
                modelID: Stage2GateFixture.modelID,
                messages: [.user("parent dual-child probe")],
                tools: toolDefinitions
            ),
            snapshot: snapshot,
            project: { event in
                try await projector.apply(event)
                await parentEvents.append(event)
                if case .approvalRequired(let runID, let toolCallID) = event,
                   runID == parentRunID {
                    try await runtime.approveToolCall(toolCallID: toolCallID, scope: .once)
                }
            }
        )
        let completion = Task<Void, Error> {
            for try await _ in stream { }
        }
        return Stage10DualChildScenario(
            store: fixture.store,
            runtime: runtime,
            parentRunID: parentRunID,
            parentEvents: parentEvents,
            childEvents: childEvents,
            providerLedger: providerLedger,
            completion: completion
        )
    }

    private static func exposure(_ descriptor: ToolDescriptor) -> ToolExposureSnapshot {
        ToolExposureSnapshot(
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            displayName: descriptor.displayName,
            description: descriptor.description,
            inputSchema: descriptor.inputSchema
        )
    }

    @Test("delegation is disabled until its runtime configuration is enabled")
    func delegationDefaultsDisabled() throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let configuration = try fixture.store.delegationConfiguration()

        #expect(!configuration.enabled)
        #expect(configuration.revision == 0)
    }

    @Test("cold-start Parent Stop settles an undispatched delegation with its actual result")
    func coldStartStopSettlesUndispatchedDelegation() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-stop-parent"
        let parentToolCallID = "stage10-stop-delegation-call"
        let uncertainCallID = "stage10-stop-unknown-call"
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-stop-trigger",
            runID: parentRunID,
            runState: .stopping
        ))
        let parent = try #require(try fixture.store.run(id: parentRunID))
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [])
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: AgentRuntime(
                store: fixture.store,
                provider: provider,
                credentials: fixture.credentials
            ),
            project: { _ in }
        )
        let executor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let waitingIntent = try executor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Start a Child."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .waitingForApproval,
            intent: String(decoding: try JSONEncoder().encode(waitingIntent), as: UTF8.self)
        ))
        let unknownIntent = try executor.prepare(
            callID: uncertainCallID,
            argumentsJSON: #"{"task":"Continue the Child."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: uncertainCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .dispatched,
            intent: String(decoding: try JSONEncoder().encode(unknownIntent), as: UTF8.self)
        ))

        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )
        let report = try await runtime.reconcileColdStartRuns()

        #expect(report.settledRunIDs == [parentRunID])
        #expect(try fixture.store.run(id: parentRunID)?.state == .cancelled)
        #expect(try fixture.store.toolCall(id: parentToolCallID)?.state == .notExecuted)
        #expect(try fixture.store.toolCall(id: uncertainCallID)?.state == .indeterminate)
        #expect(try fixture.store.toolResult(toolCallID: uncertainCallID) == nil)
        let result = try #require(try fixture.store.toolResult(toolCallID: parentToolCallID))
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        #expect(result.payload == "Delegation ended before a Child Run was created.")
    }

    @Test("Parent dependency invalidation settles an active Child before failing the Parent")
    func parentInvalidationSettlesActiveChild() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let parentRunID = "stage10-invalidation-parent"
        let childRunID = "stage10-invalidation-child"
        let parentToolCallID = "stage10-invalidation-delegation-call"
        let provider = Stage2ScriptedProvider(ledger: Stage2ProviderLedger(), scripts: [])
        let prompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: "stage10-safety",
            zenCore: "stage10-core",
            providerAdapterInstructions: provider.adapterPromptInstructions
        )
        let descriptor = SubagentDelegationTool.toolDescriptor
        var commit = Fixtures.send(
            conversationID: I05RuntimeTestFixtures.conversationID,
            messageID: "stage10-invalidation-trigger",
            runID: parentRunID,
            runState: .executingTools
        )
        commit.run.requestConfigSeed.credentialBinding = CredentialBindingSnapshot(
            reference: I05RuntimeTestFixtures.credentialReference,
            generation: 1
        )
        commit.run.executionSnapshot = try ExecutionSnapshotCodec.encode(RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [ToolExposureSnapshot(
                toolID: descriptor.id,
                descriptorRevision: descriptor.revision,
                displayName: descriptor.displayName,
                description: descriptor.description,
                inputSchema: descriptor.inputSchema
            )],
            maxProviderSteps: 4,
            delegation: DelegationExecutionSnapshot(configuration: DelegationRuntimeConfiguration(
                enabled: true,
                revision: 1
            ))
        ))
        try fixture.store.commitUserTurnAndCreateParentRun(commit)

        let parent = try #require(try fixture.store.run(id: parentRunID))
        let delegationRuntime = DelegationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            agentRuntime: AgentRuntime(
                store: fixture.store,
                provider: provider,
                credentials: fixture.credentials
            ),
            project: { _ in }
        )
        let executor = SubagentDelegationTool(
            parentRunID: parentRunID,
            store: fixture.store,
            delegationRuntime: delegationRuntime
        )
        let intent = try executor.prepare(
            callID: parentToolCallID,
            argumentsJSON: #"{"task":"Finish the requested task."}"#,
            context: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed)
        )
        let encodedIntent = try String(decoding: JSONEncoder().encode(intent), as: UTF8.self)
        try fixture.store.createToolCall(Fixtures.toolCall(
            id: parentToolCallID,
            runID: parentRunID,
            action: SubagentDelegationTool.toolID,
            state: .prepared,
            intent: encodedIntent
        ))
        try fixture.store.markToolCallDispatched(id: parentToolCallID)

        let childSnapshot = RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: prompt,
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: 4,
            delegation: nil
        )
        var child = Fixtures.run(
            id: childRunID,
            conversationID: parent.conversationID,
            kind: .child,
            state: .preparing,
            parentRunID: parentRunID
        )
        child.requestConfigSeed = parent.requestConfigSeed
        child.executionSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        try fixture.store.createDelegatedChildRun(
            parentToolCallID: parentToolCallID,
            childRun: child
        )
        try fixture.store.transitionRun(
            id: childRunID,
            expectedState: .preparing,
            to: .requestingModel
        )
        try fixture.store.transitionRun(
            id: parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .invalidate
        )

        let toolRuntime = ToolRuntime(
            store: fixture.store,
            registry: try ToolRegistry.empty.merging([executor]),
            credentials: fixture.credentials
        )
        toolRuntime.bind(registry: try ToolRegistry.empty.merging([executor]), forRunID: parentRunID)
        try await RunRecovery(store: fixture.store, toolRuntime: toolRuntime).recover(runID: parentRunID)

        let recoveredParent = try #require(try fixture.store.run(id: parentRunID))
        let recoveredChild = try #require(try fixture.store.run(id: childRunID))
        let recoveredCall = try #require(try fixture.store.toolCall(id: parentToolCallID))
        let result = try #require(try fixture.store.toolResult(toolCallID: parentToolCallID))
        #expect(recoveredParent.state == .failed)
        #expect(recoveredParent.endReason == .dependencyUnavailable)
        #expect(recoveredChild.state == .failed)
        #expect(recoveredChild.endReason == .dependencyUnavailable)
        #expect(recoveredCall.state == .failed)
        #expect(result.kind == .error)
        #expect(result.failureCode == .executionFailed)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any]
        )
        #expect(payload["childRunID"] as? String == childRunID)
        #expect(payload["state"] as? String == RunState.failed.rawValue)
        #expect(payload["endReason"] as? String == EndReason.dependencyUnavailable.rawValue)
    }
}

private struct Stage10DualChildScenario {
    let store: PersistenceStore
    let runtime: AgentRuntime
    let parentRunID: String
    let parentEvents: Stage10ApprovalLedger
    let childEvents: Stage10ApprovalLedger
    let providerLedger: Stage2ProviderLedger
    let completion: Task<Void, Error>
}

private actor Stage10DualChildMessageProjector {
    private let store: PersistenceStore

    init(store: PersistenceStore) {
        self.store = store
    }

    func apply(_ event: AgentEvent) throws {
        switch event {
        case .messagePartStarted(let runID, let messageID, let partID, let kind):
            let response = try store.ensureAssistantResponse(
                forRunID: runID,
                messageID: messageID
            )
            let sequence = (try store.parts(ofMessage: response.id).map(\.sequence).max() ?? -1) + 1
            try store.createPart(MessagePartRecord(
                id: partID,
                messageID: response.id,
                sequence: sequence,
                kind: kind,
                state: .streaming,
                payload: try PersistenceStore.encodeTextPayload(.init(text: ""))
            ))
        case .messagePartDelta(_, let partID, let delta, _):
            try store.appendText(toPart: partID, delta: delta)
        case .messagePartCompleted(_, let partID, let state):
            try store.finishPart(id: partID, state: state)
        case .runAccepted, .runStateChanged, .toolCallChanged, .approvalRequired, .runEnded:
            break
        }
    }
}

private enum Stage10DualChildProviderMode: Sendable, Equatable {
    case returnResults
    case stopWithKnownResults
}

private struct Stage10DualChildProvider: ModelProvider {
    static let knownToolID = "stage10-dual-child-known"
    static let holdToolID = "stage10-dual-child-hold"

    let ledger: Stage2ProviderLedger
    let mode: Stage10DualChildProviderMode

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "stage10-dual-child-probe.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: Stage2GateFixture.modelID,
            providerInstanceID: instance.id,
            displayName: "Stage 10 dual Child probe model",
            capabilities: [.text, .streaming, .tools]
        )]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown model")
        }
        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://stage10-dual-child.invalid/chat/completions")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        _ = seed
        _ = credentials
        _ = await ledger.record(request)

        let events = responseEvents(for: request)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func responseEvents(for request: ProviderChatRequest) -> [ProviderStreamEvent] {
        let userText = request.messages.compactMap { message -> String? in
            guard case .user(let text) = message else { return nil }
            return text
        }.last
        let toolResults = request.messages.compactMap { message -> (String, String)? in
            guard case .toolResult(let callID, let content) = message else { return nil }
            return (callID, content)
        }

        if userText == "parent dual-child probe",
           !toolResults.contains(where: { $0.0.hasPrefix("provider-delegation-") }) {
            return [
                .toolCall(ProviderToolCall(
                    id: "provider-delegation-alpha",
                    index: 0,
                    name: SubagentDelegationTool.toolID,
                    argumentsJSON: #"{"task":"alpha child task"}"#
                )),
                .toolCall(ProviderToolCall(
                    id: "provider-delegation-beta",
                    index: 1,
                    name: SubagentDelegationTool.toolID,
                    argumentsJSON: #"{"task":"beta child task"}"#
                )),
                .finish(.toolCalls),
            ]
        }

        if toolResults.contains(where: { $0.0.hasPrefix("provider-delegation-") }) {
            return [.textDelta("parent dual-child answer"), .finish(.stop)]
        }

        guard let task = userText else {
            return [.finish(.unknown("missing probe task"))]
        }
        let childName = task.hasPrefix("alpha") ? "alpha" : "beta"
        if toolResults.contains(where: { $0.0.hasPrefix("provider-child-hold-") }) {
            return [.textDelta("\(childName) child answer"), .finish(.stop)]
        }

        var events: [ProviderStreamEvent] = []
        if mode == .stopWithKnownResults {
            events.append(.toolCall(ProviderToolCall(
                id: "provider-child-known-\(childName)",
                index: 0,
                name: Self.knownToolID,
                argumentsJSON: #"{"label":"known result for \#(childName)"}"#
            )))
        }
        events.append(.toolCall(ProviderToolCall(
            id: "provider-child-hold-\(childName)",
            index: mode == .stopWithKnownResults ? 1 : 0,
            name: Self.holdToolID,
            argumentsJSON: "{}"
        )))
        events.append(.finish(.toolCalls))
        return events
    }
}

private struct Stage10ColdApprovalScenario {
    let store: PersistenceStore
    let runtime: ConversationRuntime
    let events: Stage10ApprovalLedger
    let providerLedger: Stage2ProviderLedger
    let toolLedger: I07ToolLedger
    let parentRunID: String
    let childRunID: String
    let parentToolCallID: String
    let childToolCallID: String
}

private actor Stage10DelegationEventLedger {
    private var approvalIDs: [String] = []
    private var approvalWaiters: [CheckedContinuation<String, Never>] = []

    func append(_ event: AgentEvent) {
        guard case .approvalRequired(_, let toolCallID) = event else { return }
        approvalIDs.append(toolCallID)
        let waiters = approvalWaiters
        approvalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: toolCallID)
        }
    }

    func waitForApproval() async -> String {
        if let toolCallID = approvalIDs.first { return toolCallID }
        return await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }
}

private actor Stage10ApprovalLedger {
    private var approvals: [(runID: String, toolCallID: String)] = []
    private var waiters: [(index: Int, continuation: CheckedContinuation<(runID: String, toolCallID: String), Never>)] = []
    private var runApprovalWaiters: [(runID: String, continuation: CheckedContinuation<(runID: String, toolCallID: String), Never>)] = []
    private var differentRunApprovalWaiters: [(runID: String, continuation: CheckedContinuation<(runID: String, toolCallID: String), Never>)] = []
    private var runStates: [(runID: String, state: RunState)] = []
    private var stateWaiters: [(runID: String, state: RunState, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ event: AgentEvent) {
        switch event {
        case .approvalRequired(let runID, let toolCallID):
            let approval = (runID, toolCallID)
            approvals.append(approval)
            let ready = waiters.filter { $0.index < approvals.count }
            waiters.removeAll { $0.index < approvals.count }
            for waiter in ready {
                waiter.continuation.resume(returning: approvals[waiter.index])
            }
            let runReady = runApprovalWaiters.filter { $0.runID == runID }
            runApprovalWaiters.removeAll { $0.runID == runID }
            for waiter in runReady {
                waiter.continuation.resume(returning: approval)
            }
            let differentRunReady = differentRunApprovalWaiters.filter { $0.runID != runID }
            differentRunApprovalWaiters.removeAll { $0.runID != runID }
            for waiter in differentRunReady {
                waiter.continuation.resume(returning: approval)
            }
        case .runStateChanged(let runID, let state):
            runStates.append((runID, state))
            let ready = stateWaiters.filter { $0.runID == runID && $0.state == state }
            stateWaiters.removeAll { $0.runID == runID && $0.state == state }
            for waiter in ready { waiter.continuation.resume() }
        default:
            break
        }
    }

    func waitForApproval(at index: Int) async -> (runID: String, toolCallID: String) {
        if approvals.indices.contains(index) { return approvals[index] }
        return await withCheckedContinuation { continuation in
            waiters.append((index, continuation))
        }
    }

    func waitForApproval(runID: String) async -> (runID: String, toolCallID: String) {
        if let approval = approvals.first(where: { $0.runID == runID }) { return approval }
        return await withCheckedContinuation { continuation in
            runApprovalWaiters.append((runID, continuation))
        }
    }

    func waitForApproval(onRunDifferentFrom runID: String) async -> (runID: String, toolCallID: String) {
        if let approval = approvals.first(where: { $0.runID != runID }) { return approval }
        return await withCheckedContinuation { continuation in
            differentRunApprovalWaiters.append((runID, continuation))
        }
    }

    func waitForRunState(runID: String, state: RunState) async {
        if runStates.contains(where: { $0.runID == runID && $0.state == state }) { return }
        await withCheckedContinuation { continuation in
            stateWaiters.append((runID, state, continuation))
        }
    }
}
