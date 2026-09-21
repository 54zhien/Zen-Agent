import Foundation
import Testing

@testable import ZenAgent

@Suite("Provider streaming contract")
struct ProviderStreamingContractTests {

    private let instance = ProviderInstance(
        id: ProviderInstanceID(rawValue: "fake-instance"),
        providerID: .deepSeek,
        displayName: "Fake",
        baseURL: nil,
        configRevision: .initial,
        credentialReference: CredentialReference(id: "fake-credential")
    )

    private func request(modelID: String = "fake-model") -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: ModelID(rawValue: modelID),
            messages: [ProviderChatMessage(role: .user, content: "Hello")]
        )
    }

    private func seed(for modelID: String = "fake-model") -> RequestConfigSeed {
        RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: modelID),
            credentialBinding: CredentialBindingSnapshot(
                reference: CredentialReference(id: "fake-credential"),
                generation: 1
            ),
            resolvedEndpoint: URL(string: "https://example.com/chat/completions")!
        )
    }

    private func credentials() -> CredentialStore {
        CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
    }

    private func drain(
        _ stream: AsyncThrowingStream<ProviderStreamEvent, Error>
    ) async throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test("any ModelProvider preserves the scripted provider-neutral event order")
    func providerNeutralEventsStayOrdered() async throws {
        let expected: [ProviderStreamEvent] = [
            .reasoningDelta("think first"),
            .textDelta("answer"),
            .finish(.stop),
            .usage(ProviderTokenUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5)),
        ]
        let provider: any ModelProvider = FakeProvider(
            instanceID: instance.id,
            modelNames: ["fake-model"],
            scriptedEvents: expected
        )

        let events = try await drain(
            try await provider.stream(
                request(),
                seed: seed(),
                instance: instance,
                credentials: credentials()
            )
        )

        #expect(events == expected)
    }

    @Test("an unknown model fails explicitly through the Provider seam")
    func unknownModelFailsExplicitly() async throws {
        let provider: any ModelProvider = FakeProvider(
            instanceID: instance.id,
            modelNames: ["fake-model"]
        )

        var failure: Error?
        do {
            _ = try await provider.stream(
                request(modelID: "missing-model"),
                seed: seed(modelID: "missing-model"),
                instance: instance,
                credentials: credentials()
            )
        } catch {
            failure = error
        }

        #expect(failure as? ProviderError == .invalidRequest("unknown model missing-model"))
    }
}
