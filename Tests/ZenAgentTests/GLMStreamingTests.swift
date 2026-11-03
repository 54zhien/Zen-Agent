import Foundation
import GRDB
import Testing

@testable import ZenAgent

private final class GLMRuntimeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[Data]]
    private var sent: [HTTPRequest] = []

    init(scripts: [[String]]) {
        self.scripts = scripts.map { $0.map { Data($0.utf8) } }
    }

    var requests: [HTTPRequest] {
        lock.withLock { sent }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPTransportError.networkFailure("the GLM runtime test only scripts streams")
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let chunks = lock.withLock { () -> [Data] in
            sent.append(request)
            return scripts.removeFirst()
        }
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            },
            cancel: {}
        )
    }
}

@Suite("GLM streaming")
struct GLMStreamingTests {
    private struct Fixture {
        let provider: GLMProvider
        let transport: FakeHTTPTransport
        let credentials: CredentialStore
        let seed: RequestConfigSeed
    }

    private func makeFixture() throws -> Fixture {
        let transport = FakeHTTPTransport()
        let provider = GLMProvider(transport: transport)
        let reference = CredentialReference(id: "glm-stream-test-key")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("glm-stream-secret"), as: reference)
        let metadata = try #require(try credentials.metadata(for: reference))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "glm-stream-instance"),
            providerID: .glm,
            displayName: "GLM",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        return Fixture(
            provider: provider,
            transport: transport,
            credentials: credentials,
            seed: try provider.makeRequestConfigSeed(
                instance: instance,
                modelID: GLMProvider.defaultModelID,
                credentialBinding: CredentialBindingSnapshot(
                    reference: metadata.reference,
                    generation: metadata.bindingGeneration
                )
            )
        )
    }

    @Test("reasoning, answer, fragmented tool arguments, usage, and finish retain protocol order")
    func streamReassemblesGLMEvents() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"reasoning_content":"Check the forecast."}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"content":"Rain"}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Oslo\"}"}}]}}]}"# + "\n\n",
            #"data: {"id":"glm-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":4,"total_tokens":11}}"# + "\n\n",
            "data: [DONE]\n\n",
        ])

        let events = try await drain(try await fixture.provider.stream(
            ProviderChatRequest(modelID: GLMProvider.defaultModelID, messages: [.user("Weather?")]),
            seed: fixture.seed,
            credentials: fixture.credentials
        ))

        #expect(events == [
            .reasoningDelta("Check the forecast."),
            .textDelta("Rain"),
            .toolCall(ProviderToolCall(
                id: "call_weather",
                index: 0,
                name: "get_weather",
                argumentsJSON: "{\"city\":\"Oslo\"}"
            )),
            .usage(ProviderTokenUsage(promptTokens: 7, completionTokens: 4, totalTokens: 11)),
            .finish(.toolCalls),
        ])
    }


    @Test("a recovered GLM tool round returns its original reasoning unchanged")
    func recoveredToolRoundRetainsExactReasoning() async throws {
        let databaseURL = try Fixtures.scratchPath(name: "glm-reasoning.sqlite")
        let checkpointURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("glm-reasoning-checkpoint.sqlite")
        defer { Fixtures.cleanUp(databaseURL) }

        let conversationID = "glm-reasoning-\(UUID().uuidString)"
        let instanceID = ProviderInstanceID(rawValue: "glm-reasoning-\(UUID().uuidString)")
        let credentialReference = CredentialReference(id: "glm-reasoning-\(UUID().uuidString)")
        let runDatabase = try ZenDatabase.open(at: databaseURL.path(), migrator: Migrations.makeMigrator())
        let store = PersistenceStore(database: runDatabase)
        try store.database.write { db in
            try Fixtures.conversation(id: conversationID).insert(db)
        }
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("glm-runtime-test-key"), as: credentialReference)
        try store.createProviderInstance(ProviderInstance(
            id: instanceID,
            providerID: .glm,
            displayName: "GLM",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: credentialReference
        ))

        let providerCallID = "glm-runtime-tool-call"
        let reasoning = "Preserve this exact reasoning.\nSecond line stays intact."
        let transport = GLMRuntimeHTTPTransport(scripts: [
            [
                #"data: {"id":"glm-runtime","choices":[{"index":0,"delta":{"reasoning_content":"Preserve this exact "}}]}"# + "\n\n",
                #"data: {"id":"glm-runtime","choices":[{"index":0,"delta":{"reasoning_content":"reasoning.\nSecond line stays intact."}}]}"# + "\n\n",
                #"data: {"id":"glm-runtime","choices":[{"index":0,"delta":{"content":"Checking."}}]}"# + "\n\n",
                #"data: {"id":"glm-runtime","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"glm-runtime-tool-call","type":"function","function":{"name":"stage2_side_effect","arguments":"{}"}}]}}]}"# + "\n\n",
                #"data: {"id":"glm-runtime","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ],
            [
                #"data: {"id":"glm-runtime-continued","choices":[{"index":0,"delta":{"content":"Done."}}]}"# + "\n\n",
                #"data: {"id":"glm-runtime-continued","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ],
        ])
        let provider = GLMProvider(transport: transport)
        let sideEffects = SideEffectLedger()
        let liveToolRegistry = try ToolRegistry(tools: [Stage2SideEffectTool(ledger: sideEffects)])
        let liveEvents = I05EventRecorder()
        let liveRuntime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            onEvent: { await liveEvents.append($0) },
            toolRegistry: liveToolRegistry
        )
        let command = SendCommand(
            conversationID: conversationID,
            text: "Run the approved tool.",
            providerInstanceID: instanceID,
            modelID: GLMProvider.defaultModelID,
            maxProviderSteps: 4,
            submissionID: "glm-reasoning-\(UUID().uuidString)"
        )

        let runID = try await liveRuntime.start(command)
        let waitingRunID = await liveEvents.waitForState(.waitingForApproval)
        #expect(waitingRunID == runID)
        #expect(transport.requests.count == 1)

        let backupSource = try DatabaseQueue(path: databaseURL.path())
        let checkpoint = try DatabaseQueue(path: checkpointURL.path())
        try backupSource.backup(to: checkpoint)
        try await liveRuntime.stop(runID: runID)
        try await liveRuntime.waitForCompletion(runID: runID)
        #expect(try store.run(id: runID)?.state == .cancelled)

        let recoveredStore = PersistenceStore(database: try ZenDatabase.open(
            at: checkpointURL.path(),
            migrator: Migrations.makeMigrator()
        ))
        let recoveredCredentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try recoveredCredentials.provision(
            SecretValue("glm-runtime-test-key"),
            as: credentialReference
        )
        let recoveredRuntime = ConversationRuntime(
            store: recoveredStore,
            provider: provider,
            credentials: recoveredCredentials,
            toolRegistry: try ToolRegistry(tools: [Stage2SideEffectTool(ledger: sideEffects)])
        )

        let report = try await recoveredRuntime.reconcileColdStartRuns()
        #expect(report.continuedRunIDs == [runID])
        let recoveredCall = try #require(try recoveredStore.toolCalls(inRun: runID).first)
        #expect(recoveredCall.providerCallID == providerCallID)
        #expect(recoveredCall.state == .waitingForApproval)
        #expect(transport.requests.count == 1)

        let approval = try #require(try await recoveredRuntime.pendingToolApprovals(
            in: conversationID
        ).first)
        #expect(approval.toolCallID == recoveredCall.id)
        try await recoveredRuntime.resolveToolApproval(approval.request(for: .approveOnce))
        try await Fixtures.awaitRuntimeCompletion(
            in: recoveredStore,
            runtime: recoveredRuntime,
            runID: runID
        )

        #expect(try recoveredStore.run(id: runID)?.state == .completed)
        #expect((await sideEffects.snapshot()).count == 1)
        let requests = transport.requests
        #expect(requests.count == 2)
        guard requests.count == 2,
              let body = requests.last?.body,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let thinking = root["thinking"] as? [String: Any],
              let messages = root["messages"] as? [[String: Any]],
              let assistant = messages.first(where: {
                  $0["role"] as? String == "assistant" && $0["tool_calls"] != nil
              })
        else {
            #expect(false, "the recovered GLM continuation must include its streamed protocol history")
            return
        }
        #expect(thinking["clear_thinking"] as? Bool == false)
        #expect(assistant["reasoning_content"] as? String == reasoning)
        #expect(assistant["content"] as? String == "Checking.")
        #expect(messages.contains(where: {
            $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == providerCallID
        }))
    }

    @Test("legacy tool transcripts decode without a reasoning field")
    func legacyToolTranscriptHasNoReasoning() throws {
        let encoded = #"{"version":1,"assistantContent":"visible","calls":[{"id":"call","index":0,"name":"tool","argumentsJSON":"{}"}]}"#
        let transcript = try JSONDecoder().decode(
            ToolCallProtocolTranscript.self,
            from: Data(encoded.utf8)
        )
        #expect(transcript.version == ToolCallProtocolTranscript.currentVersion)
        #expect(transcript.assistantReasoning == nil)
    }

    @Test("GLM stream terminal reasons retain their provider meaning")
    func terminalReasonsKeepGLMSemantics() throws {
        let cases: [(String, FinishReason)] = [
            ("stop", .stop),
            ("length", .length),
            ("tool_calls", .toolCalls),
            ("content_filter", .contentFilter),
            ("sensitive", .contentFilter),
            ("network_error", .interrupted),
            ("insufficient_system_resource", .interrupted),
        ]

        for (wireReason, expected) in cases {
            var decoder = GLMChatCompletionStreamDecoder()
            let payload = #"{"choices":[{"delta":{},"finish_reason":"\#(wireReason)"}]}"#
            let output = try decoder.consume(payload)
            #expect(output.events == [.finish(expected)])
        }
    }

    @Test("a stream without the GLM terminator is reported as interrupted")
    func missingTerminatorIsInterrupted() async throws {
        let fixture = try makeFixture()
        fixture.transport.enqueueStream([
            #"data: {"id":"glm-2","choices":[{"index":0,"delta":{"content":"partial"}}]}"# + "\n\n",
        ])

        var failure: ProviderError?
        do {
            _ = try await drain(try await fixture.provider.stream(
                ProviderChatRequest(modelID: GLMProvider.defaultModelID, messages: [.user("Hi")]),
                seed: fixture.seed,
                credentials: fixture.credentials
            ))
        } catch let error as ProviderError {
            failure = error
        }

        guard case .streamInterrupted(let deliveredOutput, _) = failure else {
            Issue.record("expected an interrupted GLM stream, got \(String(describing: failure))")
            return
        }
        #expect(deliveredOutput)
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}