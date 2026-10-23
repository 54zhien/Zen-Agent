import Foundation
import Testing
@testable import ZenAgent

@Suite("Environment secret disclosure boundary")
struct EnvironmentDisclosureTests {
    @Test("the real Tool result boundary redacts an unactivated global Environment secret", .timeLimit(.minutes(1)))
    func statelessToolCannotDiscloseGlobalEnvironmentSecret() async throws {
        let secret = "fixture-environment-secret-for-tool-result"
        let tool = FixedEnvironmentDisclosureTool(secret: secret)
        let registry = try ToolRegistry(tools: [tool])
        let fixture = try MemoryPromptFixture.make(registry: registry, scripts: [
            .events([.toolCall(.init(id: "environment-disclosure-call", index: 0,
                name: tool.descriptor.id, argumentsJSON: "{}")), .finish(.toolCalls)]),
            .events([.textDelta("The tool result was received."), .finish(.stop)])
        ])
        let environment = EnvironmentRuntime(store: fixture.store, credentials: fixture.credentials)
        _ = try await environment.saveSecret(key: "FIXTURE_REGION_TOKEN", value: SecretValue(secret))

        // This global secret is intentionally not activated through any Skill.
        let command = fixture.command(text: "Run the fixture disclosure probe")
        let runID = try await fixture.runtime.start(command,
            creatingConversationIfMissing: Fixtures.conversation(id: command.conversationID))
        var displayedApproval: ToolApprovalProjection?
        for _ in 0..<1_000 {
            let approvals = try await fixture.runtime.pendingToolApprovals(in: command.conversationID)
            displayedApproval = approvals.first
            if displayedApproval != nil { break }
            let currentRun = try fixture.store.run(id: runID)
            if currentRun?.state.isTerminal == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let displayedApproval {
            try await fixture.runtime.resolveToolApproval(displayedApproval.request(for: .approveOnce))
        } else {
            let currentRun = try fixture.store.run(id: runID)
            if currentRun?.state.isTerminal != true {
                try await fixture.runtime.stop(runID: runID)
                try await fixture.runtime.waitForCompletion(runID: runID)
                Issue.record("The real Tool pipeline should execute or display an approval")
                return
            }
        }
        try await fixture.runtime.waitForCompletion(runID: runID)

        let storedRun = try fixture.store.run(id: runID)
        let run = try #require(storedRun)
        #expect(run.state == .completed)
        let encodedSnapshot = try #require(run.executionSnapshot)
        #expect(!encodedSnapshot.contains(secret))
        let snapshot = try ExecutionSnapshotCodec.decode(encodedSnapshot)
        #expect(snapshot.prompt.skillReferences.isEmpty)

        let calls = try fixture.store.toolCalls(inRun: runID)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.state == .succeeded)
        let storedResult = try fixture.store.toolResult(toolCallID: call.id)
        let durableResult = try #require(storedResult)
        #expect(durableResult.payload.contains("[REDACTED]"))
        #expect(!durableResult.payload.contains(secret))

        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.count == 2)
        let continuationResults = requests.dropFirst().flatMap { $0.messages }.compactMap { message -> String? in
            guard case .toolResult(_, let content) = message else { return nil }
            return content
        }
        #expect(continuationResults.contains(where: { $0.contains("[REDACTED]") }))
        #expect(continuationResults.allSatisfy({ !$0.contains(secret) }))
    }
}

private struct FixedEnvironmentDisclosureTool: ToolExecutable {
    let secret: String

    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "fixture_environment_disclosure", displayName: "Fixture disclosure probe",
            description: "Returns a fixed test value.",
            inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]),
            revision: "1", sideEffect: .none, approvalRequirement: .required,
            actions: [.init(toolID: "fixture_environment_disclosure", actionID: "disclose_fixture",
                descriptorRevision: "1", risk: .high, allowsAutomaticApproval: false,
                allowsConversationGrant: false, resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolArgumentJSON.requireEmptyObject(argumentsJSON)
        var intent = try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "disclose_fixture",
            normalizedArgumentsJSON: "{}", resource: .notRequired, destination: .notRequired)
        intent.approvalDisclosure = ToolApprovalDisclosure(toolDisplayName: descriptor.displayName,
            action: "Return one fixed fixture value", targetDescription: "Disclosure test fixture",
            keyImpact: "The result is subject to the normal Tool result boundary")
        return intent
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        guard intent.toolID == descriptor.id, intent.descriptorRevision == descriptor.revision else {
            throw ToolExecutionError.invalidIntent
        }
        return ToolExecutionResult(content: "Fixture result: \(secret)")
    }
}
