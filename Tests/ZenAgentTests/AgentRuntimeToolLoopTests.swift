import Foundation
import Testing

@testable import ZenAgent

struct I07ToolInvocation: Sendable, Equatable {
    var toolID: String
    var argumentsJSON: String
    var idempotencyKey: String
    var dispatchCount: Int
    var outcome: String
}

struct I07PersistedToolResult: Sendable, Equatable {
    var toolCallID: String
    var payload: String
}

actor I07ToolLedger {
    private var invocations: [I07ToolInvocation] = []
    private var dispatchWaiters: [(required: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordDispatch(
        toolID: String,
        argumentsJSON: String,
        idempotencyKey: String
    ) {
        let dispatchCount = invocations.filter {
            $0.idempotencyKey == idempotencyKey
        }.count + 1
        invocations.append(
            I07ToolInvocation(
                toolID: toolID,
                argumentsJSON: argumentsJSON,
                idempotencyKey: idempotencyKey,
                dispatchCount: dispatchCount,
                outcome: "dispatched"
            )
        )

        let ready = dispatchWaiters.filter { $0.required <= invocations.count }
        dispatchWaiters.removeAll { $0.required <= invocations.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func recordSuccess(idempotencyKey: String) {
        guard let index = invocations.lastIndex(where: {
            $0.idempotencyKey == idempotencyKey
        }) else { return }
        invocations[index].outcome = "succeeded"
    }

    func snapshot() -> [I07ToolInvocation] {
        invocations
    }

    func waitForDispatchCount(_ required: Int) async {
        guard invocations.count < required else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if invocations.count >= required {
                continuation.resume()
            } else {
                dispatchWaiters.append((required: required, continuation: continuation))
            }
        }
    }
}

struct I07RecordingTool: ToolExecutable {
    enum ExecutionMode: Sendable, Equatable {
        case normal
        case waitForCancellation
    }

    let descriptor: ToolDescriptor
    private let ledger: I07ToolLedger
    private let executionMode: ExecutionMode

    init(
        id: String,
        approvalRequirement: ToolApprovalRequirement,
        ledger: I07ToolLedger,
        executionMode: ExecutionMode = .normal
    ) {
        self.ledger = ledger
        self.executionMode = executionMode
        self.descriptor = ToolDescriptor(
            id: id,
            displayName: "I07 \(id)",
            description: "A test-only tool that records dispatches.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
            ]),
            revision: "i07-test-tool.v1",
            sideEffect: .externalWrite,
            approvalRequirement: approvalRequirement
        )
    }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        let normalized = try ToolArgumentJSON.normalizedObject(object)
        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: normalized,
            targetIdentity: callID,
            destinationIdentity: nil
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        guard
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision
        else {
            throw ToolExecutionError.invalidIntent
        }

        await ledger.recordDispatch(
            toolID: descriptor.id,
            argumentsJSON: intent.normalizedArgumentsJSON,
            idempotencyKey: idempotencyKey
        )
        if executionMode == .waitForCancellation {
            try await Task.sleep(for: .seconds(60))
        }
        await ledger.recordSuccess(idempotencyKey: idempotencyKey)
        return ToolExecutionResult(
            content: "\(descriptor.id) executed: \(intent.normalizedArgumentsJSON)"
        )
    }
}

actor I07EventLedger {
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
        if let toolCallID = approvalIDs.first {
            return toolCallID
        }
        return await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }
}

/// A deterministic provider used by the I07 probes. It records structured requests
/// and serves one scripted response per request, so a continuation cannot hide behind
/// a provider implementation that silently reuses one stream.
actor I07ProviderLedger {
    private var requests: [ProviderChatRequest] = []
    private var toolInvocationsAtRequest: [[I07ToolInvocation]] = []
    private var durableResultsAtRequest: [[I07PersistedToolResult]] = []

    func record(
        _ request: ProviderChatRequest,
        toolInvocations: [I07ToolInvocation],
        durableResults: [I07PersistedToolResult]
    ) -> Int {
        let index = requests.count
        requests.append(request)
        toolInvocationsAtRequest.append(toolInvocations)
        durableResultsAtRequest.append(durableResults)
        return index
    }

    func requestsSnapshot() -> [ProviderChatRequest] { requests }

    func toolInvocations(atRequest index: Int) -> [I07ToolInvocation] {
        toolInvocationsAtRequest[index]
    }

    func durableResults(atRequest index: Int) -> [I07PersistedToolResult] {
        durableResultsAtRequest[index]
    }
}

struct I07ScriptedProvider: ModelProvider {
    let ledger: I07ProviderLedger
    let instanceID: ProviderInstanceID
    let scripts: [[ProviderStreamEvent]]
    let toolLedger: I07ToolLedger?
    let store: PersistenceStore?
    let conversationID: String?

    init(
        ledger: I07ProviderLedger,
        instanceID: ProviderInstanceID,
        scripts: [[ProviderStreamEvent]],
        toolLedger: I07ToolLedger? = nil,
        store: PersistenceStore? = nil,
        conversationID: String? = nil
    ) {
        self.ledger = ledger
        self.instanceID = instanceID
        self.scripts = scripts
        self.toolLedger = toolLedger
        self.store = store
        self.conversationID = conversationID
    }

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "i07-scripted-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: I05RuntimeTestFixtures.modelID,
            providerInstanceID: instance.id,
            displayName: "I07 fake model",
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
            resolvedEndpoint: URL(string: "https://fake.invalid/chat/completions")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        _ = seed
        _ = credentials
        let toolInvocations: [I07ToolInvocation]
        if let toolLedger {
            toolInvocations = await toolLedger.snapshot()
        } else {
            toolInvocations = []
        }
        let durableResults: [I07PersistedToolResult]
        if let store,
           let conversationID,
           let run = try store.activeParentRuns(inConversation: conversationID).first {
            durableResults = try store.toolCalls(inRun: run.id).compactMap { call in
                guard let result = try store.toolResult(toolCallID: call.id) else {
                    return nil
                }
                return I07PersistedToolResult(
                    toolCallID: result.toolCallID,
                    payload: result.payload
                )
            }
        } else {
            durableResults = []
        }
        let requestIndex = await ledger.record(
            request,
            toolInvocations: toolInvocations,
            durableResults: durableResults
        )
        let events = scripts[min(requestIndex, scripts.count - 1)]
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Suite("Agent runtime tool loop")
struct AgentRuntimeToolLoopTests {
    @Test("a tool call must execute and continue in the same assistant response")
    func toolCallReachesSecondModelRequest() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = I07ProviderLedger()
        let toolLedger = I07ToolLedger()
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: #"{"value":"hello"}"#
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("continued after tool"),
                    .finish(.stop),
                ],
            ],
            toolLedger: toolLedger,
            store: fixture.store,
            conversationID: I05RuntimeTestFixtures.conversationID
        )
        let toolRegistry = try ToolRegistry(tools: [
            I07RecordingTool(
                id: "echo",
                approvalRequirement: .notRequired,
                ledger: toolLedger
            ),
            I07RecordingTool(
                id: "approval-required",
                approvalRequirement: .required,
                ledger: toolLedger
            ),
        ])
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: toolRegistry
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let run = try fixture.store.run(id: runID)
        let assistantMessages = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .assistant }
        let requests = await ledger.requestsSnapshot()
        let invocations = await toolLedger.snapshot()

        #expect(requests.count == 2)
        #expect(run?.state == .completed)
        #expect(assistantMessages.count == 1)
        guard requests.count > 1 else {
            #expect(false, "the second provider request must exist")
            return
        }

        guard let responseID = run?.responseMessageID else {
            #expect(false, "the completed run must point to its assistant response")
            return
        }
        guard let assistant = assistantMessages.first else {
            #expect(false, "the tool continuation must materialize an assistant response")
            return
        }
        #expect(responseID == assistant.id)

        let parts = try fixture.store.parts(ofMessage: assistant.id)
        let text = try parts
            .filter { $0.kind == .text }
            .compactMap { try fixture.store.text(ofPart: $0.id) }
            .joined()
        #expect(text == "continued after tool")

        let calls = try fixture.store.toolCalls(inRun: runID)
        #expect(calls.count == 1)
        guard let call = calls.first else {
            #expect(false, "the registered tool must create a durable ToolCall")
            return
        }
        #expect(call.providerCallID == "provider-call-0")
        #expect(call.batchID != nil && !(call.batchID?.isEmpty ?? true))
        #expect(call.batchSequence == 0)
        #expect(call.state == .succeeded)

        guard let result = try fixture.store.toolResult(toolCallID: call.id) else {
            #expect(false, "the executed tool must create a durable ToolResult")
            return
        }
        let expectedResult = #"echo executed: {"value":"hello"}"#
        #expect(result.toolCallID == call.id)
        #expect(result.payload == expectedResult)

        #expect(invocations.count == 1)
        guard let invocation = invocations.first else {
            #expect(false, "the registered executor must be called")
            return
        }
        #expect(invocation.toolID == "echo")
        #expect(invocation.argumentsJSON == #"{"value":"hello"}"#)
        #expect(invocation.dispatchCount == 1)
        #expect(invocation.idempotencyKey == call.id)
        #expect(invocation.outcome == "succeeded")

        let continuationResults = requests[1].messages.compactMap {
            message -> (toolCallID: String, content: String)? in
            guard case .toolResult(let toolCallID, let content) = message else {
                return nil
            }
            return (toolCallID, content)
        }
        #expect(continuationResults.count == 1)
        #expect(continuationResults.first?.toolCallID == "provider-call-0")
        #expect(continuationResults.first?.content == expectedResult)

        let resultParts = parts.filter { $0.kind == .toolResult }
        #expect(resultParts.count == 1)
        if let resultPart = resultParts.first {
            let payload = try JSONDecoder().decode(
                ToolResultPartPayload.self,
                from: Data(resultPart.payload.utf8)
            )
            #expect(payload.toolCallID == call.id)
        }
    }
}
