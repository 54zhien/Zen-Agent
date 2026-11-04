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

    @Test("Responses keeps image parts ordered in their owning user message")
    func responsesEncodeOrderedUserContent() throws {
        let request = ProviderChatRequest(
            modelID: OpenAIProvider.defaultModelID,
            messages: [
                .user("An earlier text-only turn."),
                .userContent([
                    .text("Before the picture."),
                    .image(mediaType: "image/png", data: Data([0, 255])),
                    .text("After the picture."),
                ]),
            ]
        )

        let body = try OpenAIResponsesRequest.body(for: request)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(root["input"] as? [[String: Any]])

        #expect(input.count == 2)
        #expect(input[0]["role"] as? String == "user")
        #expect(input[0]["content"] as? String == "An earlier text-only turn.")
        #expect(input[1]["role"] as? String == "user")
        let content = try #require(input[1]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["input_text", "input_image", "input_text"])
        #expect(content[0]["text"] as? String == "Before the picture.")
        #expect(content[1]["image_url"] as? String == "data:image/png;base64,AP8=")
        #expect(content[2]["text"] as? String == "After the picture.")
    }

    @Test("GLM and Anthropic reject images instead of omitting them")
    func nonVisionRequestEncodersRejectImages() throws {
        let glmRequest = imageRequest(modelID: GLMProvider.defaultModelID)
        let glmFailure = try #require(caughtProviderError {
            _ = try GLMChatCompletionRequest.body(for: glmRequest, thinkingEffort: nil)
        })
        #expect(isInvalidRequest(glmFailure))

        let anthropicRequest = imageRequest(modelID: AnthropicProvider.defaultModelID)
        let anthropicFailure = try #require(caughtProviderError {
            _ = try AnthropicMessagesRequest.body(for: anthropicRequest, maxOutputTokens: 4096)
        })
        #expect(isInvalidRequest(anthropicFailure))
    }

    @Test("DeepSeek refuses image requests before contacting its transport")
    func deepSeekRejectsImagesBeforeDispatch() async throws {
        let transport = FakeHTTPTransport()
        let provider = DeepSeekProvider(transport: transport)
        let credential = CredentialReference(id: "deepseek-image-input-test")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("deepseek-image-test-key"), as: credential)
        let metadata = try #require(try credentials.metadata(for: credential))
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "deepseek-image-input-test"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: credential
        )
        let seed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: DeepSeekProvider.modelIDs[0],
            credentialBinding: CredentialBindingSnapshot(
                reference: metadata.reference,
                generation: metadata.bindingGeneration
            )
        )

        var failure: Error?
        do {
            _ = try await provider.stream(
                imageRequest(modelID: seed.modelID),
                seed: seed,
                credentials: credentials
            )
        } catch {
            failure = error
        }

        #expect(isInvalidRequest(failure as? ProviderError))
        #expect(transport.requestCount == 0)
    }

    private func imageRequest(modelID: ModelID) -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: modelID,
            messages: [
                .userContent([
                    .text("Describe this."),
                    .image(mediaType: "image/jpeg", data: Data([1, 2, 3])),
                ]),
            ]
        )
    }

    private func caughtProviderError(_ operation: () throws -> Void) -> ProviderError? {
        do {
            try operation()
            return nil
        } catch {
            return error as? ProviderError
        }
    }

    private func isInvalidRequest(_ error: ProviderError?) -> Bool {
        guard let error else { return false }
        if case .invalidRequest = error { return true }
        return false
    }
}
