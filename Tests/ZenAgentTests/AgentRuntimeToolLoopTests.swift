import Foundation
import Testing

@testable import ZenAgent

/// A deterministic provider used by the I07 probes. It records every request and
/// serves one scripted response per request, so a continuation cannot hide behind
/// a provider implementation that silently reuses one stream.
actor I07ProviderLedger {
    private var requests: [String] = []

    func record(_ request: ProviderChatRequest) -> Int {
        let index = requests.count
        requests.append(String(describing: request))
        return index
    }

    func requestCount() -> Int { requests.count }

    func requestDescriptions() -> [String] { requests }
}

struct I07ScriptedProvider: ModelProvider {
    let ledger: I07ProviderLedger
    let instanceID: ProviderInstanceID
    let scripts: [[ProviderStreamEvent]]

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
        let requestIndex = await ledger.record(request)
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
        let provider = I07ScriptedProvider(
            ledger: ledger,
            instanceID: fixture.instance.id,
            scripts: [
                [
                    .toolCall(.init(
                        id: "provider-call-0",
                        index: 0,
                        name: "echo",
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ],
                [
                    .textDelta("continued after tool"),
                    .finish(.stop),
                ],
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let run = try fixture.store.run(id: runID)
        let assistant = try fixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).first { $0.role == .assistant }
        let text = try assistant.map { message in
            try fixture.store.parts(ofMessage: message.id)
                .compactMap { try? fixture.store.text(ofPart: $0.id) }
                .joined()
        } ?? ""
        let requests = await ledger.requestDescriptions()
        let requestCount = await ledger.requestCount()

        #expect(
            requestCount == 2 &&
                run?.state == .completed &&
                text == "continued after tool" &&
                requests.count == 2 &&
                requests[1].contains("tool")
        )
    }
}
