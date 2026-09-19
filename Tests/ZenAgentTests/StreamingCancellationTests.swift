import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **cancelling the consumer cancels the request.**
///
/// The tests that existed before this one proved a weaker thing: that when a transport
/// *reports* cancellation, the adapter maps it to `ProviderError.cancelled`. That is a
/// claim about a translation table. It says nothing about whether pressing Stop does
/// anything to the network — and a stream that keeps running after the thing that asked
/// for it has gone is exactly what `Agent Runtime.md:261` warns about: a late result
/// still arriving after the run it belonged to was stopped.
///
/// So these drive the real transport over a scripted `URLProtocol` and check the two
/// facts that were never checked: the underlying task is really cancelled, and nothing
/// is delivered afterwards.
@Suite("Streaming cancellation")
struct StreamingCancellationTests {

    /// Counts deliveries from a consuming task, which cannot hold a `var` of its own
    /// across the await.
    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() { lock.withLock { count += 1 } }
        var recorded: Int { lock.withLock { count } }
    }

    private func makeURL() -> URL {
        URL(string: "https://stub-\(UUID().uuidString).invalid/chat/completions")!
    }

    private func post(_ url: URL) -> HTTPRequest {
        HTTPRequest(method: .post, url: url, headers: [:], body: Data(#"{"stream":true}"#.utf8))
    }

    /// A stream that never ends on its own, so cancellation is the only way out.
    private func endlessScript() -> StubURLProtocol.Script {
        var script = StubURLProtocol.Script()
        script.chunks = Array(repeating: Data("data: x\n\n".utf8), count: 400)
        script.chunkDelay = 0.01
        script.stalls = true
        return script
    }

    // MARK: - The transport

    @Test("cancelling the handle cancels the underlying request")
    func cancelReachesTheNetwork() async throws {
        let url = makeURL()
        StubURLProtocol.register(endlessScript(), for: url)

        // The **whole** handle is held. An earlier version took `.body` and dropped the
        // handle, then expected the transport to notice on its own that the consumer had
        // gone — which was the contract before this refactor, and was the thing that did
        // not work. This tests the contract that replaced it.
        let handle = try await URLSessionHTTPTransport(session: StubURLProtocol.makeSession()).stream(post(url))
        let deliveries = Deliveries()

        let consumer = Task {
            do {
                for try await _ in handle.body { deliveries.record() }
            } catch {
                // Cancellation may surface as a thrown error or as a clean end. Either
                // is a stopped stream; this test is not about which.
            }
        }

        // Let it get properly under way before stopping it.
        try await Task.sleep(for: .milliseconds(60))
        let beforeCancelling = deliveries.recorded
        #expect(beforeCancelling > 0, "the stream should have delivered something before it was cancelled")

        // The holder ends the transfer. One call, and the point of the type.
        handle.cancel()
        _ = await consumer.value

        #expect(
            StubURLProtocol.stopCount(for: url) >= 1,
            """
            HTTPStream.cancel() did not reach the URLSession task. A connection held \
            open by a result nobody is waiting for is what Agent Runtime.md:261 warns \
            about, and it is what this handle exists to prevent.
            """
        )

        // And the server stops being read. Counted on the stub's side, not the
        // consumer's: a counter the consumer increments cannot move once the consumer
        // has stopped, so asserting it did not move would prove nothing. This one keeps
        // climbing if the underlying task was never cancelled — which is the failure
        // being tested for.
        let atRest = StubURLProtocol.deliveryCount(for: url)
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            StubURLProtocol.deliveryCount(for: url) == atRest,
            """
            the stub delivered \(StubURLProtocol.deliveryCount(for: url) - atRest) more \
            chunks after the consumer stopped — the request is still running
            """
        )
    }

    // MARK: - Through the adapter

    /// Named for what it checks, not for more.
    ///
    /// The assertion below accepts either a clean end or `.cancelled`, so this does
    /// **not** prove the error is always `.cancelled`. What it proves is the pair that
    /// matters: the request reached the network and was cancelled there, and no failure
    /// was invented for a user who asked to stop.
    @Test("cancelling a provider consumer reaches the network without inventing a failure")
    func cancellationReachesTheNetworkWithoutAFailure() async throws {
        let endpoint = URL(string: "https://stub-\(UUID().uuidString).invalid")!
        let reference = CredentialReference(id: "cred-1")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("sk-cancel-probe"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: endpoint,
            configRevision: .initial,
            credentialReference: reference
        )
        let seed = RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-flash"),
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1)
        )
        let requestURL = endpoint.appending(path: "chat/completions")
        StubURLProtocol.register(endlessScript(), for: requestURL)

        // A deadline far out, so nothing but the cancellation can end this.
        let policy = StreamTimeoutPolicy(
            transportInactivity: .seconds(30),
            firstEvent: .seconds(30),
            betweenEvents: .seconds(30),
            checkInterval: .milliseconds(20)
        )
        let provider = DeepSeekProvider(
            transport: URLSessionHTTPTransport(session: StubURLProtocol.makeSession(), timeouts: policy),
            streamTimeouts: policy
        )

        let consumer = Task { () -> ProviderError? in
            do {
                for try await _ in try await provider.stream(
                    ProviderChatRequest(
                        modelID: ModelID(rawValue: "deepseek-flash"),
                        messages: [ProviderChatMessage(role: .user, content: "Hello")]
                    ),
                    seed: seed,
                    instance: instance,
                    credentials: credentials
                ) {}
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                // Reported rather than folded into `nil`. `nil` is accepted below as a
                // clean end, so swallowing here would make any non-Zen error escaping
                // `stream()` indistinguishable from a correct cancellation — and this
                // test's whole point is the negative.
                Issue.record("a non-Zen error escaped the adapter: \(error)")
                return nil
            }
        }

        // Wait until the request has produced something, rather than for a fixed
        // duration. Cancelling before the transfer is established cancels nothing, and
        // the test then fails with `stopCount == 0` for a reason that has nothing to do
        // with cancellation — which is how it failed intermittently at 85ms.
        for _ in 0..<200 where StubURLProtocol.deliveryCount(for: requestURL) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            StubURLProtocol.deliveryCount(for: requestURL) > 0,
            "the stream never delivered anything, so there was nothing to cancel"
        )

        consumer.cancel()
        let outcome = await consumer.value

        // A user who pressed Stop did not experience a failure, and reporting one would
        // put an error in front of them for something they asked for. Both accepted
        // outcomes are non-failures; this does not assert which one arrives.
        #expect(
            outcome == nil || outcome == .cancelled,
            "cancellation surfaced as \(String(describing: outcome))"
        )
        #expect(
            StubURLProtocol.stopCount(for: requestURL) >= 1,
            "the request was never cancelled"
        )
    }
}
