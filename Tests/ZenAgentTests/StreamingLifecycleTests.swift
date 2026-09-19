import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **every way the Provider stops consuming a response also ends the
/// request that is producing it.**
///
/// The refactor that introduced `HTTPStream` was motivated by cancellation, but
/// cancellation was only the path anyone had thought to test. Every other way a stream
/// ends has the same obligation and no coverage:
///
/// | exit | why the request would otherwise keep running |
/// |---|---|
/// | the user cancelling | nobody wants the answer |
/// | a progress deadline | the model stopped, and waiting longer changes nothing |
/// | a malformed SSE frame | the bytes cannot be trusted, so the rest are worthless |
/// | a chunk that will not decode | same, one layer up |
/// | `[DONE]` | the answer is complete; the connection is not the answer |
///
/// Each test asserts on the **transport**, not on the stream. A stream that ends while
/// the request it came from is still running is the failure being tested for, and
/// asserting that the caller stopped is exactly the assertion that cannot detect it.
///
/// The user-cancellation path is covered against the real transport in
/// `StreamingCancellationTests`, because it needs a request that is genuinely still in
/// flight rather than one that has already been scripted to finish.
@Suite("Streaming lifecycle")
struct StreamingLifecycleTests {

    // MARK: - Fixture

    struct Fixture {
        let provider: DeepSeekProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let seed: RequestConfigSeed
        let credentials: CredentialStore
    }

    /// Deadlines short enough to exercise, generous enough not to race.
    private func policy(betweenEvents: Duration = .seconds(30), firstEvent: Duration = .seconds(30)) -> StreamTimeoutPolicy {
        StreamTimeoutPolicy(
            transportInactivity: .seconds(30),
            firstEvent: firstEvent,
            betweenEvents: betweenEvents,
            checkInterval: .milliseconds(15)
        )
    }

    private func makeFixture(policy: StreamTimeoutPolicy = StreamTimeoutPolicy(
        transportInactivity: .seconds(30),
        firstEvent: .seconds(30),
        betweenEvents: .seconds(30),
        checkInterval: .milliseconds(15)
    )) throws -> Fixture {
        let reference = CredentialReference(id: "cred-1")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("sk-lifecycle-probe"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: reference
        )
        let transport = FakeHTTPTransport()
        return Fixture(
            provider: DeepSeekProvider(transport: transport, streamTimeouts: policy),
            transport: transport,
            instance: instance,
            seed: RequestConfigSeed(
                instance: instance,
                modelID: ModelID(rawValue: "deepseek-flash"),
                credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1)
            ),
            credentials: credentials
        )
    }

    private func request() -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: ModelID(rawValue: "deepseek-flash"),
            messages: [ProviderChatMessage(role: .user, content: "Hello")]
        )
    }

    /// Runs the stream to whatever end it reaches, swallowing the outcome — these tests
    /// are about what happened to the *request*, not about how the answer ended.
    private func exhaust(_ f: Fixture) async {
        do {
            for try await _ in try await f.provider.stream(
                request(), seed: f.seed, instance: f.instance, credentials: f.credentials
            ) {}
        } catch {
            // Expected. The exit path is the subject of the test, not its result.
        }
    }

    private func expectTransferEnded(_ f: Fixture, _ exit: String) {
        #expect(
            f.transport.streamCancellations >= 1,
            """
            \(exit) ended the answer and left the request running. Every way the \
            provider stops consuming a response has to end the transfer behind it, \
            otherwise "the answer stopped" and "the request stopped" are two different \
            things and only the first one happens.
            """
        )
    }

    // MARK: - Exit paths

    @Test("the terminator ends the transfer, not only the answer")
    func doneEndsTheTransfer() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(["data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
                                   "data: [DONE]\n\n"])

        await exhaust(f)

        expectTransferEnded(f, "[DONE]")
    }

    @Test("a malformed SSE frame ends the transfer")
    func malformedSSEEndsTheTransfer() async throws {
        let f = try makeFixture()
        // 0xFF can never begin a valid UTF-8 sequence.
        f.transport.enqueueStream(bytes: [Data("data: ".utf8) + Data([0xFF, 0xFE]) + Data("\n\n".utf8)])

        await exhaust(f)

        expectTransferEnded(f, "a malformed SSE frame")
    }

    @Test("a chunk that will not decode ends the transfer")
    func malformedChunkEndsTheTransfer() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(["data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n",
                                   "data: not json at all\n\n"])

        await exhaust(f)

        expectTransferEnded(f, "a chunk that would not decode")
    }

    @Test("a progress deadline ends the transfer")
    func progressTimeoutEndsTheTransfer() async throws {
        // One real chunk, then silence with the request still open. The deadline is what
        // ends it — and ending the answer is not enough on its own.
        let f = try makeFixture(policy: policy(betweenEvents: .milliseconds(120)))
        f.transport.stallStream(after: ["data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"])

        await exhaust(f)

        expectTransferEnded(f, "a progress deadline")
    }

    @Test("a stream that finishes has still ended its transfer")
    func normalCompletionEndsTheTransfer() async throws {
        let f = try makeFixture()
        f.transport.enqueueStream(["data: [DONE]\n\n"])

        await exhaust(f)

        expectTransferEnded(f, "a completed stream")
    }
}
