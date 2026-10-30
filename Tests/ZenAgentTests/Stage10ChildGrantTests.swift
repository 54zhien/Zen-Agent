import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage 10 Child Tool grants")
struct Stage10ChildGrantTests {
    @Test("Child approval belongs to its Run and does not cross the Parent Conversation")
    func childOnceGrantUsesItsRunSubject() throws {
        let fixture = try Stage10ChildGrantFixture.make()
        let parentGrantCall = try fixture.createToolCall(id: "parent-grant-call", runID: fixture.parentRunID)
        let parentPolicy = try fixture.store.toolPolicy(
            toolID: fixture.tool.id,
            actionID: fixture.actionID,
            descriptorRevision: fixture.tool.revision
        )
        let parentBinding = try fixture.binding(for: parentGrantCall)
        let parentGrant = ToolScopedGrant(
            kind: .conversation,
            subject: .parentConversation(fixture.conversationID),
            toolID: fixture.tool.id,
            actionID: fixture.actionID,
            descriptorRevision: fixture.tool.revision,
            resource: .notRequired,
            destination: .notRequired,
            validity: .active,
            revocationEpoch: parentPolicy.revocationEpoch,
            issuedFor: ToolGrantApprovalBinding(
                toolCallID: parentGrantCall.id,
                agentRunID: fixture.parentRunID,
                intentBinding: parentBinding
            )
        )
        #expect(try fixture.store.issueToolGrant(
            id: "parent-conversation-grant",
            grant: parentGrant,
            expectedPolicy: parentPolicy
        ))

        let childCall = try fixture.createToolCall(id: fixture.childCallID, runID: fixture.childRunID)
        #expect(childCall.state == .waitingForApproval)
        guard childCall.state == .waitingForApproval else { return }

        let approved = try fixture.approve(childCall, scope: .once)
        #expect(approved.state == .approved)
        let childGrants = try fixture.store.toolGrants(subject: .run(fixture.childRunID))
        #expect(childGrants.count == 1)
        let childGrant = try #require(childGrants.first?.grant)
        #expect(childGrant.subject == .run(fixture.childRunID))
        #expect(childGrant.issuedFor?.toolCallID == fixture.childCallID)
        #expect(childGrant.issuedFor?.agentRunID == fixture.childRunID)
        if case .once(let callID, let runID, let intentBinding) = childGrant.kind {
            #expect(callID == fixture.childCallID)
            #expect(runID == fixture.childRunID)
            #expect(ToolPolicyIdentity.equals(intentBinding, try fixture.binding(for: childCall)))
        } else {
            Issue.record("Child approval must grant only its original ToolCall once")
        }
        #expect(try fixture.store.toolGrants(subject: .parentConversation(fixture.conversationID))
            .map(\.id) == ["parent-conversation-grant"])

        try #require(try fixture.store.revokeToolGrant(id: "parent-conversation-grant"))
        let parentFollowUp = try fixture.createToolCall(id: "parent-follow-up", runID: fixture.parentRunID)
        #expect(parentFollowUp.state == .waitingForApproval)
    }

    @Test("Child approval cannot create a Conversation grant")
    func childConversationScopeIsRejected() throws {
        let fixture = try Stage10ChildGrantFixture.make()
        let call = try fixture.createToolCall(id: fixture.childCallID, runID: fixture.childRunID)
        #expect(call.state == .waitingForApproval)

        let result = try fixture.approve(call, scope: .conversation)

        #expect(result.state == .rejected)
        #expect(try fixture.store.toolGrants(subject: .run(fixture.childRunID)).isEmpty)
        #expect(try fixture.store.toolGrants(subject: .parentConversation(fixture.conversationID)).isEmpty)
    }

    @Test("Parent Stop prevents approval of the Child's original pending call")
    func parentStopSettlesChildApprovalWithoutGrant() throws {
        let fixture = try Stage10ChildGrantFixture.make()
        let call = try fixture.createToolCall(id: fixture.childCallID, runID: fixture.childRunID)
        try fixture.store.transitionRun(
            id: fixture.parentRunID,
            expectedState: .executingTools,
            to: .stopping,
            at: Fixtures.epoch
        )

        let result = try fixture.approve(call, scope: .once)

        #expect(result.state == .notExecuted)
        #expect(try fixture.store.toolGrants(subject: .run(fixture.childRunID)).isEmpty)
        #expect(try fixture.store.toolResult(toolCallID: fixture.childCallID) == nil)
    }

    @Test("Parent resume recovery preserves the linked Child's pending approval")
    func parentResumeCanApproveOriginalChildCall() throws {
        let fixture = try Stage10ChildGrantFixture.make()
        let call = try fixture.createToolCall(id: fixture.childCallID, runID: fixture.childRunID)
        try fixture.store.transitionRun(
            id: fixture.parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .resume,
            at: Fixtures.epoch
        )

        let result = try fixture.approve(call, scope: .once)

        #expect(result.state == .approved)
        #expect(try fixture.store.toolGrants(subject: .run(fixture.childRunID)).count == 1)
    }

    @Test("Parent invalidation rejects approval before it can issue Child authority")
    func parentInvalidationRejectsChildApproval() throws {
        let fixture = try Stage10ChildGrantFixture.make()
        let call = try fixture.createToolCall(id: fixture.childCallID, runID: fixture.childRunID)
        try fixture.store.transitionRun(
            id: fixture.parentRunID,
            expectedState: .executingTools,
            to: .recovering,
            recoveryAction: .invalidate,
            at: Fixtures.epoch
        )

        let result = try fixture.approve(call, scope: .once)

        #expect(result.state == .rejected)
        #expect(result.failureReason == .dependencyChanged)
        #expect(try fixture.store.toolGrants(subject: .run(fixture.childRunID)).isEmpty)
    }

    @Test("Child tools stay within the frozen Parent exposure and exclude recursive Subagent")
    func delegatedChildToolsAreParentSubsetWithoutSubagent() throws {
        let fixture = try Stage10ChildGrantFixture.make(createChild: false)
        #expect(throws: (any Error).self) {
            try fixture.createChild(id: "foreign-child", tools: [fixture.foreignTool])
        }
        #expect(throws: (any Error).self) {
            try fixture.createChild(id: "recursive-child", tools: [SubagentDelegationTool.toolDescriptor])
        }

        let child = try fixture.createChild(id: fixture.childRunID, tools: [fixture.tool])
        let childSnapshot = try ExecutionSnapshotCodec.decode(try #require(child.executionSnapshot))
        #expect(childSnapshot.exposedTools.map(\.toolID) == [fixture.tool.id])
        #expect(childSnapshot.exposedTools.map(\.descriptorRevision) == [fixture.tool.revision])
        #expect(try fixture.store.delegatedChildRunID(parentToolCallID: fixture.parentToolCallID) == fixture.childRunID)
    }

    @Test("Child freezes only exact Parent memory and Skill references")
    func delegatedChildPersistsParentContextSubset() throws {
        let fixture = try Stage10ChildGrantFixture.make(
            createChild: false,
            frozenSkillEnvironmentKeys: ["STAGE10_PUBLIC"],
            requestedEnvironmentKeys: ["STAGE10_PUBLIC"]
        )
        let foreignMemory = try fixture.store.saveMemory(
            content: "A Memory outside the frozen Parent snapshot.",
            at: Fixtures.epoch
        )
        #expect(throws: (any Error).self) {
            try fixture.createChild(
                id: "foreign-memory-child",
                tools: [fixture.tool],
                memoryReferences: [foreignMemory.reference]
            )
        }
        let foreignSkill = try fixture.store.saveUserSkill(
            id: nil,
            expectedRevisionID: nil,
            definition: SkillDefinition(
                name: "Unselected Child Skill",
                summary: "Outside Parent context",
                instructions: "Must not be added to a Child."
            )
        )
        try fixture.store.enableSkill(id: foreignSkill.id)
        let foreignSkillReference = SkillActivationReference(
            skillID: foreignSkill.id,
            revisionID: foreignSkill.revisionID,
            environmentReferences: [],
            environmentFingerprint: EnvironmentBindingIdentity.fingerprint(
                skillID: foreignSkill.id,
                keys: [],
                references: []
            )
        )
        #expect(throws: (any Error).self) {
            try fixture.createChild(
                id: "foreign-skill-child",
                tools: [fixture.tool],
                skillReferences: [foreignSkillReference]
            )
        }

        let child = try fixture.createChild(
            id: fixture.childRunID,
            tools: [fixture.tool],
            memoryReferences: fixture.parentMemoryReferences,
            skillReferences: fixture.parentSkillReferences
        )
        let snapshot = try ExecutionSnapshotCodec.decode(try #require(child.executionSnapshot))

        #expect(snapshot.prompt.memoryReferences == fixture.parentMemoryReferences)
        #expect(snapshot.prompt.skillReferences == fixture.parentSkillReferences)
        #expect(try fixture.store.runSkillReferences(runID: fixture.childRunID) == fixture.parentSkillReferences)
    }

    @Test("Child Skill Environment refs require explicit Parent ToolCall keys")
    func delegatedChildSkillRequiresExplicitEnvironmentKey() throws {
        let fixture = try Stage10ChildGrantFixture.make(
            createChild: false,
            frozenSkillEnvironmentKeys: ["STAGE10_PUBLIC"]
        )

        #expect(throws: (any Error).self) {
            try fixture.createChild(
                id: fixture.childRunID,
                tools: [fixture.tool],
                skillReferences: fixture.parentSkillReferences
            )
        }
        #expect(try fixture.store.delegatedChildRunID(parentToolCallID: fixture.parentToolCallID) == nil)
    }
}

private struct Stage10ChildGrantFixture {
    let store: PersistenceStore
    let parentRunID = "stage10-grant-parent"
    let childRunID = "stage10-grant-child"
    let parentToolCallID = "stage10-grant-delegation-call"
    let childCallID = "stage10-grant-child-call"
    let conversationID = "stage10-grant-conversation"
    let actionID = "read"
    let tool: ToolDescriptor
    let foreignTool: ToolDescriptor
    let parentRequestConfig: RequestConfigSeed
    let parentMemoryReferences: [MemoryRevisionReference]
    let parentSkillReferences: [SkillActivationReference]

    private init(
        store: PersistenceStore,
        tool: ToolDescriptor,
        foreignTool: ToolDescriptor,
        parentRequestConfig: RequestConfigSeed,
        parentMemoryReferences: [MemoryRevisionReference],
        parentSkillReferences: [SkillActivationReference]
    ) {
        self.store = store
        self.tool = tool
        self.foreignTool = foreignTool
        self.parentRequestConfig = parentRequestConfig
        self.parentMemoryReferences = parentMemoryReferences
        self.parentSkillReferences = parentSkillReferences
    }

    static func make(
        createChild: Bool = true,
        frozenSkillEnvironmentKeys: [String] = [],
        requestedEnvironmentKeys: [String] = []
    ) throws -> Stage10ChildGrantFixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let tool = makeTool(id: "stage10_child_tool")
        let foreignTool = makeTool(id: "stage10_foreign_tool")
        let configuration = try store.setDelegationEnabled(true, at: Fixtures.epoch)
        let memoryReferences: [MemoryRevisionReference]
        let skillReferences: [SkillActivationReference]
        if frozenSkillEnvironmentKeys.isEmpty && requestedEnvironmentKeys.isEmpty {
            memoryReferences = []
            skillReferences = []
        } else {
            let memory = try store.saveMemory(content: "A frozen Parent memory for the Child task.", at: Fixtures.epoch)
            memoryReferences = [memory.reference]
            var environmentReferences: [EnvironmentRevisionReference] = []
            for key in frozenSkillEnvironmentKeys {
                let item = try store.saveEnvironmentValue(
                    id: nil,
                    expectedRevisionID: nil,
                    scope: .global,
                    key: key,
                    value: .plain("stage10-value"),
                    at: Fixtures.epoch
                )
                environmentReferences.append(item.reference)
            }
            let skill = try store.saveUserSkill(
                id: nil,
                expectedRevisionID: nil,
                definition: SkillDefinition(
                    name: "Stage 10 Child Skill",
                    summary: "Frozen Child context",
                    instructions: "Use the frozen Parent skill context.",
                    environmentKeys: frozenSkillEnvironmentKeys
                )
            )
            try store.enableSkill(id: skill.id)
            let skillReference = SkillActivationReference(
                skillID: skill.id,
                revisionID: skill.revisionID,
                environmentReferences: environmentReferences,
                environmentFingerprint: EnvironmentBindingIdentity.fingerprint(
                    skillID: skill.id,
                    keys: frozenSkillEnvironmentKeys,
                    references: environmentReferences
                )
            )
            skillReferences = [skillReference]
        }
        let prompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: "stage10-safety",
            zenCore: "stage10-core",
            providerAdapterInstructions: "stage10-provider",
            memoryReferences: memoryReferences,
            skillReferences: skillReferences
        )
        let parentSnapshot = RunExecutionSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "stage10-adapter-v1",
            prompt: prompt,
            modelCapabilities: [.text, .streaming, .tools],
            exposedTools: [
                exposure(SubagentDelegationTool.toolDescriptor),
                exposure(tool),
            ],
            maxProviderSteps: 4,
            delegation: DelegationExecutionSnapshot(configuration: configuration)
        )
        var commit = Fixtures.send(
            conversationID: "stage10-grant-conversation",
            messageID: "stage10-grant-trigger",
            runID: "stage10-grant-parent",
            runState: .executingTools
        )
        commit.skillReferences = skillReferences
        commit.run.executionSnapshot = try ExecutionSnapshotCodec.encode(parentSnapshot)
        try store.commitUserTurnAndCreateParentRun(commit)
        let parent = try #require(try store.run(id: "stage10-grant-parent"))
        let delegationIntent = try ToolIntentCodec.freeze(
            descriptor: SubagentDelegationTool.toolDescriptor,
            actionID: SubagentDelegationTool.actionID,
            normalizedArgumentsJSON: try ToolArgumentJSON.normalizedObject([
                "task": "Use the Child tool.",
                "environmentKeys": requestedEnvironmentKeys,
            ]),
            resource: .target(parent.id),
            destination: ToolPreparationContext(requestConfigSeed: parent.requestConfigSeed).destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: SubagentDelegationTool.toolDescriptor.displayName,
                action: "Start one Child Run",
                targetDescription: "Parent Run \(parent.id)",
                keyImpact: "The Child result returns through this ToolCall."
            )
        )
        let encodedDelegationIntent = String(decoding: try JSONEncoder().encode(delegationIntent), as: UTF8.self)
        try store.createToolCall(Fixtures.toolCall(
            id: "stage10-grant-delegation-call",
            runID: parent.id,
            action: SubagentDelegationTool.toolID,
            state: .dispatched,
            intent: encodedDelegationIntent
        ))
        let fixture = Stage10ChildGrantFixture(
            store: store,
            tool: tool,
            foreignTool: foreignTool,
            parentRequestConfig: parent.requestConfigSeed,
            parentMemoryReferences: memoryReferences,
            parentSkillReferences: skillReferences
        )
        if createChild {
            _ = try fixture.createChild(id: fixture.childRunID, tools: [tool])
        }
        return fixture
    }

    func createChild(
        id: String,
        tools: [ToolDescriptor],
        memoryReferences: [MemoryRevisionReference] = [],
        skillReferences: [SkillActivationReference] = []
    ) throws -> AgentRunRecord {
        let parent = try #require(try store.run(id: parentRunID))
        let prompt = PromptExecutionSnapshot(
            runtimeSafetyBaseline: "stage10-safety",
            zenCore: "stage10-core",
            providerAdapterInstructions: "stage10-provider",
            memoryReferences: memoryReferences,
            skillReferences: skillReferences
        )
        let childSnapshot = RunExecutionSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "stage10-adapter-v1",
            prompt: prompt,
            modelCapabilities: tools.isEmpty ? [.text, .streaming] : [.text, .streaming, .tools],
            exposedTools: tools.map(Self.exposure),
            maxProviderSteps: 4
        )
        var child = Fixtures.run(
            id: id,
            conversationID: parent.conversationID,
            kind: .child,
            state: .preparing,
            parentRunID: parent.id
        )
        child.requestConfigSeed = parentRequestConfig
        child.executionSnapshot = try ExecutionSnapshotCodec.encode(childSnapshot)
        try store.createDelegatedChildRun(parentToolCallID: parentToolCallID, childRun: child)
        return try #require(try store.run(id: id))
    }

    func createToolCall(id: String, runID: String) throws -> ToolCallRecord {
        if runID == childRunID,
           try store.run(id: childRunID)?.state == .preparing {
            try store.transitionRun(
                id: childRunID,
                expectedState: .preparing,
                to: .requestingModel,
                at: Fixtures.epoch
            )
            try store.transitionRun(
                id: childRunID,
                expectedState: .requestingModel,
                to: .toolRequested,
                at: Fixtures.epoch
            )
            try store.transitionRun(
                id: childRunID,
                expectedState: .toolRequested,
                to: .executingTools,
                at: Fixtures.epoch
            )
        }
        let intent = try ToolIntentCodec.freeze(
            descriptor: tool,
            actionID: actionID,
            normalizedArgumentsJSON: "{}",
            resource: .notRequired,
            destination: .notRequired,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: tool.displayName,
                action: "Read Child task data",
                targetDescription: "Local Stage 10 fixture",
                keyImpact: "Read once for this call."
            )
        )
        let encoded = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        let result = try store.createToolCallWithPolicy(
            Fixtures.toolCall(id: id, runID: runID, action: tool.id, state: .validated, intent: encoded),
            descriptor: tool,
            safetyCap: .unrestricted,
            at: Fixtures.epoch
        )
        if runID == childRunID, result.state == .waitingForApproval {
            try store.transitionRun(
                id: childRunID,
                expectedState: .executingTools,
                to: .waitingForApproval,
                at: Fixtures.epoch
            )
        }
        return result
    }

    func approve(_ call: ToolCallRecord, scope: ToolApprovalScope) throws -> ToolCallRecord {
        try store.approveToolCallWithPolicy(
            id: call.id,
            expectedAttempt: call.attempt,
            descriptor: tool,
            safetyCap: .unrestricted,
            checkedIntentBinding: try binding(for: call),
            displayedIntentBinding: try binding(for: call),
            scope: scope,
            at: Fixtures.epoch
        )
    }

    func binding(for call: ToolCallRecord) throws -> String {
        try ToolIntentBinding.make(#require(call.executionIntent))
    }

    private static func makeTool(id: String) -> ToolDescriptor {
        ToolDescriptor(
            id: id,
            displayName: "Stage 10 Child Tool",
            description: "Persistence authorization fixture",
            inputSchema: .object([:]),
            revision: "r1",
            sideEffect: .none,
            approvalRequirement: .required,
            actions: [ToolPolicyActionMetadata(
                toolID: id,
                actionID: "read",
                descriptorRevision: "r1",
                risk: .high,
                allowsAutomaticApproval: false,
                allowsConversationGrant: true,
                resourceRequirement: .notRequired,
                egressRequirement: .notRequired
            )]
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
}
