import Foundation
import Testing

@testable import ZenAgent

enum I05CredentialMutation: Sendable {
    case none
    case logout
    case rebind
}

struct I05FailingProvider: ModelProvider {
    let failure: ProviderError
    let instanceID: ProviderInstanceID
    let partialText: String?
    let credentialMutation: I05CredentialMutation
    let seedFailure: Bool

    init(
        failure: ProviderError,
        instanceID: ProviderInstanceID,
        partialText: String? = nil,
        credentialMutation: I05CredentialMutation = .none,
        seedFailure: Bool = false
    ) {
        self.failure = failure
        self.instanceID = instanceID
        self.partialText = partialText
        self.credentialMutation = credentialMutation
        self.seedFailure = seedFailure
    }

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
        if seedFailure {
            throw ProviderError.invalidRequest("seed construction failed")
        }
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
        let partialText = partialText
        if let credentialStore = credentials as? CredentialStore {
            switch credentialMutation {
            case .none:
                break
            case .logout:
                try credentialStore.logout(I05RuntimeTestFixtures.credentialReference)
            case .rebind:
                try credentialStore.rebind(
                    SecretValue("i05-moved-secret"),
                    as: I05RuntimeTestFixtures.credentialReference,
                    principalFingerprint: "i05-moved-account"
                )
            }
        }
        return AsyncThrowingStream { continuation in
            if let partialText {
                continuation.yield(.textDelta(partialText))
            }
            continuation.finish(throwing: failure)
        }
    }
}

@Suite("Agent runtime failure mapping")
struct AgentRuntimeFailureTests {

    private func run(
        with failure: ProviderError,
        expected reason: EndReason,
        partialText: String? = nil,
        credentialMutation: I05CredentialMutation = .none
    ) async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = I05FailingProvider(
            failure: failure,
            instanceID: fixture.instance.id,
            partialText: partialText,
            credentialMutation: credentialMutation
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

        if let partialText {
            guard let responseID = record?.responseMessageID else {
                #expect(false, "partial provider output must bind an assistant response")
                return
            }
            let parts = try fixture.store.parts(ofMessage: responseID)
            #expect(parts.count == 1)
            #expect(parts[0].state == .failed)
            #expect(try fixture.store.text(ofPart: parts[0].id) == partialText)
        }
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

    @Test("an authentication-required failure suspends after flushing partial output")
    func authenticationRequiredSuspendsWithPartialOutput() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = I05FailingProvider(
            failure: .credentialRejected,
            instanceID: fixture.instance.id,
            partialText: "before auth",
            credentialMutation: .logout
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials
        )

        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        let record = try fixture.store.run(id: runID)
        #expect(record?.state == .suspended)
        #expect(record?.suspendReason == .authRequired)
        #expect(record?.endReason == nil)
        #expect(record?.activeSlot == I05RuntimeTestFixtures.conversationID)

        guard let responseID = record?.responseMessageID else {
            #expect(false, "suspended partial output must bind an assistant response")
            return
        }
        let parts = try fixture.store.parts(ofMessage: responseID)
        #expect(parts.count == 1)
        #expect(parts[0].state == .failed)
        #expect(try fixture.store.text(ofPart: parts[0].id) == "before auth")
    }

    @Test("a moved credential binding fails after flushing partial output")
    func movedCredentialBindingFailsWithPartialOutput() async throws {
        try await run(
            with: .credentialRejected,
            expected: .credentialExpired,
            partialText: "before rebinding",
            credentialMutation: .rebind
        )
    }
}
