import Foundation
import Testing

@testable import ZenAgent

@Suite("Tool result guard")
struct ToolResultGuardTests {
    @Test func oversizedMultibyteResultIsNeverPersistedOrReturned() async throws {
        let f = try ResultGuardFixture(content: String(repeating: "界", count: 22_000))
        let result = try #require(try await f.complete())
        #expect(result.content.utf8.count <= 65_536)
        #expect(result.content.contains("resultTooLarge"))
        #expect(try f.payload() == result.content)
        #expect(try f.call().state == .failed)
    }

    @Test func credentialFieldsAndBearerTokensAreRedactedBeforeStorage() async throws {
        let token = "sk-" + String(repeating: "x", count: 32)
        let f = try ResultGuardFixture(content: "{\"api_key\":\"\(token)\",\"text\":\"normal\"} Authorization: Bearer abcdefghijklmnopqrstuvwxyz")
        let result = try #require(try await f.complete())
        #expect(!result.content.contains(token))
        #expect(!result.content.contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(result.content.contains("normal"))
        #expect(try f.payload() == result.content)
    }

    @Test func genericTokenAndEscapedKnownCredentialAreRedacted() {
        let result = ToolResultGuard.sanitize(ToolExecutionResult(content: "{\"token\":\"opaque-fixture-token\",\"text\":\"normal\"}"), knownSecrets: [])
        #expect(!result.content.contains("opaque-fixture-token"))
        #expect(result.content.contains("normal"))
        let secret = SecretValue("fixture/quoted\"credential")
        let escaped = "{\"data\":\"fixture\\/quoted\\\"credential\"}"
        let guarded = ToolResultGuard.sanitize(ToolExecutionResult(content: escaped), knownSecrets: [secret])
        #expect(!guarded.content.contains("credential"))
        #expect(guarded.content.contains("[REDACTED]"))
    }

    @Test func rawExecutorErrorDoesNotReachDurableResult() async throws {
        let f = try ResultGuardFixture(content: "", throwsSecret: true)
        do { _ = try await f.complete() } catch { }
        let payload = try f.payload()
        #expect(!payload.contains("private-error-material"))
        #expect(payload.contains("executionFailed"))
        #expect(try f.call().state == .failed)
    }

    @Test func invalidTextResultIsRejectedBeforeContinuation() async throws {
        let f = try ResultGuardFixture(content: "text\u{0}binary")
        let result = try #require(try await f.complete())
        #expect(!result.content.contains("\u{0}"))
        #expect(result.content.contains("invalidResult"))
        #expect(try f.call().state == .failed)
    }
}

private struct ResultGuardFixture: Sendable {
    let store: PersistenceStore
    let runtime: ToolRuntime
    init(content: String, throwsSecret: Bool = false) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        let registry = try Fixtures.automaticallyAllowedRegistry(in: store,
            tools: [ResultGuardProbe(content: content, throwsSecret: throwsSecret)])
        self.store = store; runtime = ToolRuntime(store: store, registry: registry)
    }
    func complete() async throws -> ToolExecutionResult? {
        try await runtime.complete(agentRunID: "r", providerCallID: "pc", toolID: "result_guard_probe", argumentsJSON: "{}", batchID: "b", batchSequence: 0)
    }
    func call() throws -> ToolCallRecord { try #require(try store.toolCalls(inRun: "r").first) }
    func payload() throws -> String { try #require(try store.toolResult(toolCallID: call().id)).payload }
}

private struct ResultGuardProbe: ToolExecutable {
    let content: String
    let throwsSecret: Bool
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "result_guard_probe", displayName: "Result guard probe", description: "Test-only result", inputSchema: .object([:]), revision: "1", sideEffect: .none, approvalRequirement: .notRequired,
            actions: [.init(toolID: "result_guard_probe", actionID: "result", descriptorRevision: "1", risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true, resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "result", normalizedArgumentsJSON: "{}", resource: .notRequired, destination: .notRequired)
    }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        if throwsSecret { throw ResultGuardProbeError() }
        return ToolExecutionResult(content: content)
    }
}
private struct ResultGuardProbeError: Error, CustomStringConvertible {
    var description: String { "private-error-material" }
}
