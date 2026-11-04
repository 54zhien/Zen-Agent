import Foundation
import Testing

@testable import ZenAgent

@Suite("OpenAI image input")
struct OpenAIImageInputTests {
    @Test("GPT-6.1 Terra advertises vision when its Responses adapter accepts images")
    func modelCapabilitiesIncludeVision() {
        let provider = OpenAIProvider(transport: FakeHTTPTransport())
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "openai-image-input-test"),
            providerID: .openAI,
            displayName: "OpenAI",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: nil
        )

        let descriptor = provider.descriptor(for: OpenAIProvider.defaultModelID, in: instance)

        #expect(descriptor?.capabilities.contains(.vision) == true)
    }
}
