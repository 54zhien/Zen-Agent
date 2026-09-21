import Foundation
import Testing

@testable import ZenAgent

@Suite("Model capabilities")
struct ModelCapabilityTests {

    private let instance = ProviderInstance(
        id: ProviderInstanceID(rawValue: "capability-instance"),
        providerID: .deepSeek,
        displayName: "Capability test",
        baseURL: nil,
        configRevision: .initial,
        credentialReference: nil
    )

    @Test("DeepSeek descriptors expose only capabilities the current adapter can execute")
    func deepSeekCapabilitiesReflectCurrentAdapter() {
        let provider = DeepSeekProvider(transport: FakeHTTPTransport())
        let models = provider.knownModels(for: instance)

        let expected: Set<ModelCapability> = [
            .text,
            .streaming,
            .reasoning,
            .tools,
        ]

        #expect(models.count == DeepSeekProvider.modelIDs.count)
        #expect(models.allSatisfy { $0.capabilities == expected })

        #expect(
            models.allSatisfy { !$0.capabilities.contains(.vision) },
            "upstream model support must not masquerade as adapter support"
        )

        #expect(
            models.allSatisfy { !$0.capabilities.contains(.files) },
            "the current ProviderChatRequest has no file-content boundary"
        )
    }

    @Test("FakeProvider capabilities are explicit and configurable")
    func fakeCapabilitiesAreConfigurable() throws {
        let provider = FakeProvider(
            instanceID: instance.id,
            modelNames: ["fake-model"],
            capabilities: [.text]
        )

        let descriptor = try #require(
            provider.descriptor(
                for: ModelID(rawValue: "fake-model"),
                in: instance
            )
        )

        #expect(descriptor.capabilities == [.text])
        #expect(!descriptor.capabilities.contains(.streaming))
        #expect(!descriptor.capabilities.contains(.reasoning))
    }

    @Test("re-stamping a descriptor for another instance preserves its capabilities")
    func restampingPreservesCapabilities() throws {
        let provider = FakeProvider(
            instanceID: ProviderInstanceID(rawValue: "original-instance"),
            modelNames: ["fake-model"],
            capabilities: [.text, .streaming]
        )

        let descriptor = try #require(
            provider.knownModels(for: instance).first
        )

        #expect(descriptor.providerInstanceID == instance.id)
        #expect(descriptor.capabilities == [.text, .streaming])
    }

    @Test("capabilities survive ModelDescriptor Codable round-trip")
    func capabilitiesAreCodable() throws {
        let descriptor = ModelDescriptor(
            id: ModelID(rawValue: "round-trip"),
            providerInstanceID: instance.id,
            displayName: "Round trip",
            capabilities: [.text, .reasoning]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(
            ModelDescriptor.self,
            from: data
        )

        #expect(decoded == descriptor)
    }

    @Test("capability types remain Sendable")
    func capabilityTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(ModelCapability.self)
        requireSendable(ModelDescriptor.self)
    }
}
