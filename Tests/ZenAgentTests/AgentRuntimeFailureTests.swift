import Foundation
import Testing

@testable import ZenAgent

struct I05FailingProvider: ModelProvider {
    let failure: ProviderError
    let instanceID: ProviderInstanceID

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "i05-failing-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: I05RuntimeTestFixtures.modelID,
            providerInstanceID: instance.id,
            displayName: "Fake model",
            capabilities: [.text, .streaming]
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
        let failure = failure
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }
}

@Suite("Agent runtime failure mapping")
struct AgentRuntimeFailureTests {

    private func run(
        with failure: ProviderError,
        expected reason: EndReason
    ) async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = I05FailingProvider(
            failure: failure,
            instanceID: fixture.instance.id
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let record = try fixture.store.run(id: runID)
        #expect(record?.state == .failed)
        #expect(record?.endReason == reason)
        #expect(record?.activeSlot == nil)
    }

    @Test("stream inactivity timeout maps to its durable run reason")
    func inactivityTimeout() async throws {
        try await run(
            with: .streamInactivityTimeout(
                after: .seconds(5),
                deliveredOutput: false
            ),
            expected: .streamInactivityTimeout
        )
    }

    @Test("stream interruption maps to its durable run reason")
    func interruptedStream() async throws {
        try await run(
            with: .streamInterrupted(deliveredOutput: true, reason: "connection closed"),
            expected: .streamInterrupted
        )
    }

    @Test("progress timeout after output is a step timeout")
    func progressTimeout() async throws {
        try await run(
            with: .streamProgressTimeout(
                phase: .betweenEvents,
                after: .seconds(5)
            ),
            expected: .stepTimeout
        )
    }

    @Test("malformed, invalid, server, and transport failures map to providerFailed")
    func providerFailures() async throws {
        try await run(
            with: .malformedResponse("not json"),
            expected: .providerFailed
        )
        try await run(
            with: .invalidParameters("bad parameter"),
            expected: .providerFailed
        )
        try await run(
            with: .serverError(status: 503),
            expected: .providerFailed
        )
        try await run(
            with: .transportFailure("connection lost"),
            expected: .providerFailed
        )
    }
}
