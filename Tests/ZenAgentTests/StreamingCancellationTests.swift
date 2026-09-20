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

    /// Waits for `condition` to hold, bounded, and reports whether it did.
    ///
    /// The same shape `StreamingLifecycleTests` uses, and for the same reason: a fact
    /// delivered by an asynchronous callback cannot be read immediately after the call
    /// that triggers it. Reading at once is a race the callback can lose, and losing it
    /// looks exactly like the thing under test having failed.
    ///
    /// The deadline is a guard against hanging, not a performance budget. The caller
    /// still asserts the fact itself afterwards, so a condition that never becomes true
    /// fails the test rather than passing it slowly — a bounded wait that always passed
    /// would be worse than the race it replaced.
    private func waitFor(
        _ condition: () -> Bool,
        attempts: Int = 500,
        every: Duration = .milliseconds(10)
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: every)
        }
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

        // Let it get properly under way before stopping it — waited for, not slept
        // through. A fixed delay is a race on a loaded runner, and this test is about
        // cancellation, not about how quickly the stub gets going.
        await waitFor { deliveries.recorded > 0 }
        #expect(
            deliveries.recorded > 0,
            "the stream should have delivered something before it was cancelled"
        )

        // The holder ends the transfer. One call, and the point of the type.
        handle.cancel()
        _ = await consumer.value

        // **Waited for, not read at once.** `handle.cancel()` calls
        // `URLSessionDataTask.cancel()`; `stopLoading` is called back by URLSession on
        // its own schedule, and the consumer's task finishing does not mean that has
        // happened. There is no ordering between them, so sampling immediately is a race
        // the callback can lose — and losing it reads as the cancellation never having
        // reached the network, which is the opposite of what occurred.
        //
        // Everything below depends on it: the assertion that the transfer stopped, and
        // the sampling that asks whether anything arrived after it did.
        await waitFor { StubURLProtocol.stopCount(for: url) >= 1 }
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
        //
        // Sampled only once the transfer is known to have stopped. Taken before that,
        // the count is still climbing, and the claim below would be about a request that
        // is still running rather than one that has been ended.
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
    ///
    /// Restored onto a real local socket. It was disabled because a scripted
    /// `URLProtocol` could not hold a stream open mid-delivery, so the consumer was never
    /// genuinely parked and the test reported `stopCount == 0` for reasons that had
    /// nothing to do with cancellation.
    @Test("cancelling a provider consumer reaches the network without inventing a failure")
    func cancellationReachesTheNetworkWithoutAFailure() async throws {
        // A valid DeepSeek event, then silence with the connection open. That is what
        // makes the consumer genuinely mid-stream - one chunk decoded, waiting for the
        // next - which is the only state in which cancelling it says anything at all
        // about cancellation.
        let event = #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"hi"}}]}"# + "\n\n"
        let server = try LocalHTTPServer(script: .chunkThenStall(event))
        server.start()
        defer { server.shutdown() }

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
            // The real socket. A run goes to the endpoint its instance names, so this is
            // also what proves the endpoint resolution reaches the network.
            baseURL: server.baseURL,
            configRevision: .initial,
            credentialReference: reference
        )
        let seed = RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-flash"),
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
        )

        // A deadline far out, so nothing but the cancellation can end this.
        let policy = StreamTimeoutPolicy(
            transportInactivity: .seconds(30),
            errorBodyDeadline: .seconds(30),
            firstEvent: .seconds(30),
            betweenEvents: .seconds(30),
            checkInterval: .milliseconds(20)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let provider = DeepSeekProvider(
            transport: URLSessionHTTPTransport(session: session, timeouts: policy),
            streamTimeouts: policy
        )

        // Raised by the consumer, from inside its own loop. A server-side count would say
        // the socket was written to; it would say nothing about whether a chunk was
        // decoded and handed over, which is the state this test needs before it cancels.
        let observed = ObservedFlag()

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
                ) {
                    observed.raise()
                }
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                // Reported rather than folded into `nil`. `nil` is accepted below as a
                // clean end, so swallowing here would make any non-Zen error escaping
                // `stream()` indistinguishable from a correct cancellation - and this
                // test's whole point is the negative.
                Issue.record("a non-Zen error escaped the adapter: \(error)")
                return nil
            }
        }

        // Readiness is what the *consumer* observed. Bounded, so a harness that never
        // delivers fails the test in seconds rather than waiting out the three-minute
        // runaway - and says which half failed.
        for _ in 0..<300 where !observed.isRaised {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            observed.isRaised,
            """
            the consumer never received a decoded chunk, so it was never mid-stream and \
            cancelling it proves nothing about cancellation
            """
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
        #expect(server.wroteChunk, "the server never wrote its event")

        // The server's own observation, not the client's report. A client that believes
        // it cancelled while the connection stays open is the failure being tested for.
        //
        // This replaces the stub's `stopCount`, which could only ever report what the
        // stub had been told to do; a real peer either sees the connection end or it
        // does not.
        for _ in 0..<300 where !server.observedPeerClose {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.observedPeerClose,
            "the server never saw the connection end - the transfer outlived the interest in it"
        )
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
    }
}
