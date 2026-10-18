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
}
