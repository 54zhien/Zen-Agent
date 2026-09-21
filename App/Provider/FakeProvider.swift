import Foundation

/// A Provider that answers without network, deterministically.
///
/// It implements `ModelProvider` — the same protocol a real adapter does — so a test
/// that passes against this one is testing the seam rather than a stand-in for it. That
/// is the whole point of building it now: the DeepSeek adapter should slot into a
/// protocol that already has a passing implementation, rather than the protocol being
/// invented alongside the HTTP code.
///
/// What it can be made to do, all of it synchronously and without randomness:
///
/// | condition | how |
/// |---|---|
/// | provider available | `.accepted`, credential readable |
/// | credential missing | no reference on the instance |
/// | credential temporarily unavailable | a backend that refuses to read |
/// | credential invalid | `.rejected`, or a logged-out credential |
/// | model exists | it is in `models` |
/// | unknown model | it is not — and the answer is `nil`, not a guess |
///
struct FakeProvider: ModelProvider {
    let id: ProviderID
    private let models: [ModelDescriptor]
    private let scriptedEvents: [ProviderStreamEvent]

    init(
        id: ProviderID = .deepSeek,
        instanceID: ProviderInstanceID = ProviderInstanceID(rawValue: "fake-instance"),
        modelNames: [String] = ["fake-model"],
        capabilities: Set<ModelCapability> = [
            .text,
            .streaming,
            .reasoning,
        ],
        scriptedEvents: [ProviderStreamEvent] = [
            .textDelta("fake")
        ]
    ) {
        self.id = id
        self.scriptedEvents = scriptedEvents
        self.models = modelNames.map {
            ModelDescriptor(
                id: ModelID(rawValue: $0),
                providerInstanceID: instanceID,
                displayName: $0,
                capabilities: capabilities
            )
        }
    }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        // Re-stamped with the instance asked about, so an instance cannot be handed
        // descriptors belonging to another one.
        models.map {
            ModelDescriptor(
                id: $0.id,
                providerInstanceID: instance.id,
                displayName: $0.displayName,
                capabilities: $0.capabilities
            )
        }
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        instance: ProviderInstance,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        guard descriptor(for: request.modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown model \(request.modelID.rawValue)")
        }

        return AsyncThrowingStream { continuation in
            for event in scriptedEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
