import Foundation
import Testing

@testable import ZenAgent

private actor BaseContractProbeRequestLedger {
    private var requests: [ProviderChatRequest] = []

    func record(_ request: ProviderChatRequest) -> Int {
        let index = requests.count
        requests.append(request)
        return index
    }

    func snapshot() -> [ProviderChatRequest] { requests }
}

private struct BaseContractProbeProvider: ModelProvider {
    let ledger: BaseContractProbeRequestLedger
    let instanceID: ProviderInstanceID

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "base-contract-probe-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        guard instance.id == instanceID else { return [] }
        return [ModelDescriptor(
            id: I05RuntimeTestFixtures.modelID,
            providerInstanceID: instance.id,
            displayName: "Base contract probe model",
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
        let events: [ProviderStreamEvent]
        if requestIndex == 0 {
            events = [
                .toolCall(.init(
                    id: "base-contract-provider-call",
                    index: 0,
                    name: "base-contract-tool",
                    argumentsJSON: "{}"
                )),
                .finish(.toolCalls),
            ]
        } else {
            events = [
                .textDelta("continued"),
                .finish(.stop),
            ]
        }

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Suite("Tool loop base contract probe")
struct ToolLoopBaseContractProbeTests {
    @Test("a provider tool call produces a real continuation and linked result Part")
    func toolCallContinuationUsesBaseContracts() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let ledger = BaseContractProbeRequestLedger()
        let providerCallID = "base-contract-provider-call"
        let provider = BaseContractProbeProvider(
            ledger: ledger,
            instanceID: fixture.instance.id
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let requests = await ledger.snapshot()
        let run = try fixture.store.run(id: runID)

        #expect(requests.count == 2)
        #expect(run?.state == .completed)

        guard let responseID = run?.responseMessageID else {
            #expect(false, "the completed run must have an assistant response")
            return
        }
        let parts = try fixture.store.parts(ofMessage: responseID)
        guard let resultPart = parts.first(where: { $0.kind == .toolResult }) else {
            #expect(false, "the continuation must persist a tool-result Part")
            return
        }
        guard let payload = try JSONSerialization.jsonObject(
            with: Data(resultPart.payload.utf8),
            options: [.fragmentsAllowed]
        ) as? [String: Any],
        let relatedToolCallID = payload["toolCallID"] as? String else {
            #expect(false, "the tool-result payload must contain its related call ID")
            return
        }

        let calls = try fixture.store.toolCalls(inRun: runID)
        guard let relatedCall = calls.first(where: { $0.id == relatedToolCallID }) else {
            #expect(false, "the Part must point to a persisted ToolCall")
            return
        }
        #expect(relatedCall.providerCallID == providerCallID)
        #expect(relatedToolCallID == relatedCall.id)
    }
}
