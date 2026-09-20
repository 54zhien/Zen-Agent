import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **"the connection is alive" and "the model is producing" are two
/// questions, and no single timer answers both.**
///
/// The suite runs the real transport over a scripted `URLProtocol`, because the question
/// is about bytes actually arriving over time and a fake would be answering for itself.
///
/// Everything here hangs on DeepSeek's real behaviour: it sends `: keep-alive` comments
/// while it thinks, sometimes for minutes before generating anything. Those bytes prove
/// the connection is healthy and say nothing whatsoever about the answer. A design with
/// one timer has to choose — and whichever it chooses, one of these tests fails.
@Suite("Streaming timeouts")
struct StreamingTimeoutTests {

    /// Deadlines measured in milliseconds.
    ///
    /// The production values are deliberately generous and deliberately not taken from
    /// the design notes (`Agent Runtime.md:297`), so no test may depend on them. These
    /// are the test's own, short enough that the whole suite runs in under a second.
    private func policy(
        liveness: Duration,
        firstEvent: Duration = .seconds(10),
        betweenEvents: Duration = .seconds(10)
    ) -> StreamTimeoutPolicy {
        StreamTimeoutPolicy(
            transportInactivity: liveness,
            errorBodyDeadline: .seconds(30),
            firstEvent: firstEvent,
            betweenEvents: betweenEvents,
            checkInterval: .milliseconds(15)
        )
    }

    // MARK: - Fixture

    struct Fixture {
        let provider: DeepSeekProvider
        let instance: ProviderInstance
        let seed: RequestConfigSeed
        let credentials: CredentialStore
        let endpoint: URL
    }

    private func makeFixture(timeouts: StreamTimeoutPolicy) throws -> Fixture {
        // A host of its own per test, so the stub's registry stays parallel-safe — and
        // the endpoint now comes from the instance, which is what makes that possible.
        let endpoint = URL(string: "https://stub-\(UUID().uuidString).invalid")!
        let reference = CredentialReference(id: "cred-1")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("sk-timeout-probe"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: endpoint,
            configRevision: .initial,
            credentialReference: reference
        )
        // The same policy to both layers: the transport reads the liveness deadline from
        // it, the adapter reads the two model deadlines. One value, so they cannot drift.
        let transport = URLSessionHTTPTransport(
            session: StubURLProtocol.makeSession(),
            timeouts: timeouts
        )
        return Fixture(
            provider: DeepSeekProvider(transport: transport, streamTimeouts: timeouts),
            instance: instance,
            seed: RequestConfigSeed(
                instance: instance,
                modelID: ModelID(rawValue: "deepseek-flash"),
                credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1),
                resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
            ),
            credentials: credentials,
            endpoint: endpoint
        )
    }

    private func register(_ script: StubURLProtocol.Script, for f: Fixture) {
        StubURLProtocol.register(script, for: f.endpoint.appending(path: "chat/completions"))
    }

    /// Streams to completion or failure, and reports which.
    private func outcome(of f: Fixture) async -> ProviderError? {
        do {
            for try await _ in try await f.provider.stream(
                ProviderChatRequest(
                    modelID: ModelID(rawValue: "deepseek-flash"),
                    messages: [ProviderChatMessage(role: .user, content: "Hello")]
                ),
                seed: f.seed,
                instance: f.instance,
                credentials: f.credentials
            ) {}
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            Issue.record("expected a ProviderError, got \(error)")
            return nil
        }
    }

    private func keepAliveScript(thenStall: Bool = true) -> StubURLProtocol.Script {
        var script = StubURLProtocol.Script()
        script.chunks = Array(repeating: Data(": keep-alive\n\n".utf8), count: 40)
        script.chunkDelay = 0.03
        script.stalls = thenStall
        return script
    }

    // MARK: - The two questions

    @Test("keep-alives keep the connection alive and do not count as the model producing")
    func keepAlivesAreNotProgress() async throws {
        // The connection is demonstrably healthy: a byte arrives every 30ms, far inside
        // a 400ms liveness window. The model produces nothing at all. Only a deadline
        // that counts *events* rather than bytes can be the one that fires — and it must
        // be, because ten minutes of heartbeats is not an answer.
        let f = try makeFixture(timeouts: policy(liveness: .milliseconds(400), firstEvent: .milliseconds(200)))
        register(keepAliveScript(), for: f)

        let result = await outcome(of: f)

        guard case .streamProgressTimeout(let phase, _) = result else {
            Issue.record(
                """
                expected the model's deadline to fire, got \(String(describing: result)). \
                A liveness timeout here would mean heartbeats were counted as progress.
                """
            )
            return
        }
        #expect(phase == .awaitingFirstEvent, "no model output ever arrived")
    }

    @Test("a connection that goes silent trips the liveness deadline, not the model's")
    func silentConnectionTripsLiveness() async throws {
        // Nothing at all arrives after the status line. The model's deadline is set far
        // out, so anything that fires here has to be about the connection.
        let f = try makeFixture(timeouts: policy(liveness: .milliseconds(150), firstEvent: .seconds(10)))
        var script = StubURLProtocol.Script()
        // One byte, and *asynchronously*. Both halves matter. `bytes(for:)` does not hand
        // back a response until the body has produced something, so a script that sends
        // nothing never establishes a stream and the test measures URLSession's default
        // timeout instead of the deadline it set. And a burst delivered synchronously
        // inside `startLoading` is not flushed to the consumer while the task stays open
        // — the sibling test that delivers asynchronously and stalls does return, which
        // is how this was narrowed down.
        script.chunks = [Data(":".utf8)]
        script.chunkDelay = 0.02
        script.stalls = true
        register(script, for: f)

        let result = await outcome(of: f)

        guard case .streamInactivityTimeout = result else {
            Issue.record(
                """
                expected the liveness deadline to fire, got \(String(describing: result)). \
                Reporting a silent connection as the model not producing would send \
                someone to look at the provider when the problem is the read timeout.
                """
            )
            return
        }
    }

    @Test("a model that stops partway is reported as stopping partway")
    func stallAfterOutputIsBetweenEvents() async throws {
        // One real chunk, then nothing but heartbeats. The first wait and the second are
        // different situations, and the error has to say which — "the model never
        // started" and "the model stopped mid-answer" call for different responses.
        let f = try makeFixture(
            timeouts: policy(liveness: .milliseconds(400), betweenEvents: .milliseconds(200))
        )
        var script = keepAliveScript()
        let firstChunk = Data(#"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"x"}}]}"#.utf8)
        script.chunks.insert(firstChunk + Data("\n\n".utf8), at: 0)
        register(script, for: f)

        let result = await outcome(of: f)

        guard case .streamProgressTimeout(let phase, _) = result else {
            Issue.record("expected a progress timeout, got \(String(describing: result))")
            return
        }
        #expect(phase == .betweenEvents, "output had already been produced, so this is a stall rather than a failure to start")
    }

    // MARK: - The snapshot a deadline reports

    @Test("the elapsed deadline carries the progress it was measured against")
    func elapsedDeadlineCarriesItsOwnSnapshot() async throws {
        // The window is chosen by whether output had arrived. If the caller then asks the
        // progress *again* to describe the wait, a chunk landing between the two reads
        // flips the answer - and a run that produced nothing at all gets reported as
        // having stalled partway.
        let progress = StreamProgress()

        try await Task.sleep(for: .milliseconds(120))
        let elapsed = try #require(
            progress.elapsedDeadline(first: .milliseconds(100), then: .seconds(30)),
            "the first-event window should have elapsed with nothing produced"
        )
        #expect(elapsed.hadAdvanced == false, "no output had arrived when the window was chosen")

        // Output arrives *after* the measurement. The reading above was a snapshot, so it
        // does not change retroactively - and that is the whole point of carrying it.
        progress.advanced()
        #expect(progress.hasAdvanced, "the live progress does now report output")

        let phaseFromSnapshot: StreamProgressPhase =
            elapsed.hadAdvanced ? .betweenEvents : .awaitingFirstEvent
        let phaseFromLiveRead: StreamProgressPhase =
            progress.hasAdvanced ? .betweenEvents : .awaitingFirstEvent

        #expect(phaseFromSnapshot == .awaitingFirstEvent)
        #expect(
            phaseFromLiveRead == .betweenEvents,
            "the live read now says the opposite, which is exactly the disagreement the snapshot removes"
        )
        #expect(
            phaseFromSnapshot != phaseFromLiveRead,
            """
            the two readings agree only because the second one is not being taken. Asking \
            the progress again to build the phase is what turns "the model never started" \
            into "the model stopped partway" - a report about a stall that did not happen.
            """
        )

        // A fresh reading is a different measurement of a different situation, and does
        // see the output that has since arrived.
        try await Task.sleep(for: .milliseconds(120))
        let later = try #require(
            progress.elapsedDeadline(first: .seconds(30), then: .milliseconds(100)),
            "the between-events window should have elapsed once output stopped"
        )
        #expect(later.hadAdvanced, "a fresh reading sees the output that has since arrived")
    }

    // MARK: - Retryability follows the Blueprint's rule

    @Test("a stall after output forbids replay; a stall before it does not permit one either")
    func dispositionsFollowTheReplayRule() {
        // The distinction is not cosmetic. Once output exists, re-sending the request asks
        // the model to generate the answer again while the caller still counts it as one
        // (`Agent Runtime.md:344`). Before output, a streaming POST still cannot prove the
        // request was never accepted, so the answer is "cannot say" rather than "safe"
        // (`Agent Runtime.md:341-343`).
        #expect(ProviderError.streamProgressTimeout(phase: .betweenEvents, after: .seconds(1)).retryDisposition == .doNotRetry)
        #expect(ProviderError.streamProgressTimeout(phase: .awaitingFirstEvent, after: .seconds(1)).retryDisposition == .retrySuggested)
        // A liveness timeout is a fact about the wire, and the wire going quiet says
        // nothing about the answer. What decides is whether output had already been
        // handed over — which is why the case carries that fact rather than leaving this
        // layer to guess from a byte count. Bytes include keep-alive comments, and a
        // minute of heartbeats followed by a dead connection produced nothing at all.
        #expect(
            ProviderError.streamInactivityTimeout(after: .seconds(1), deliveredOutput: false).retryDisposition
                == .retrySuggested,
            "keep-alives and then silence is not a partially delivered answer"
        )
        #expect(
            ProviderError.streamInactivityTimeout(after: .seconds(1), deliveredOutput: true).retryDisposition
                == .doNotRetry,
            "going quiet two thousand tokens in must not be replayed"
        )

        // And nothing here is ever "safe to retry".
        let streamFailures: [ProviderError] = [
            .streamInactivityTimeout(after: .seconds(1), deliveredOutput: false),
            .streamInactivityTimeout(after: .seconds(1), deliveredOutput: true),
            .streamProgressTimeout(phase: .awaitingFirstEvent, after: .seconds(1)),
            .streamProgressTimeout(phase: .betweenEvents, after: .seconds(1)),
            .streamInterrupted(deliveredOutput: false, reason: "x"),
            .streamInterrupted(deliveredOutput: true, reason: "x"),
        ]
        for error in streamFailures {
            #expect(
                error.retryDisposition != .retryable,
                "\(error) claimed to be provably safe to retry, which no streaming failure is"
            )
        }
    }

    // MARK: - The shape of the policy

    /// **Relations, not numbers.**
    ///
    /// The values are a starting point and the notes forbid taking them from anywhere but
    /// observed provider behaviour (`Agent Runtime.md:297`), so pinning one here would
    /// assert a decision nobody has made. What must not drift is the ordering the
    /// arguments rest on:
    ///
    /// - The error-body deadline is a **total** for a body the server has already
    ///   written. `firstEvent` waits on a model that has to be *run* before it can say
    ///   anything, so waiting for an error envelope cannot be allowed to outlast waiting
    ///   for the model — that would be more patient with what has already happened than
    ///   with what has not.
    /// - It is tighter than `transportInactivity` too, because that window is re-armed by
    ///   every byte and is therefore the one thing a trickle can hold open forever.
    @Test("the error-body deadline stays tighter than the waits it is argued against")
    func errorBodyDeadlineIsTheTightest() {
        let policy = StreamTimeoutPolicy.default
        #expect(
            policy.errorBodyDeadline < policy.firstEvent,
            "a body the server has already produced may not be waited on longer than one it has not"
        )
        #expect(
            policy.errorBodyDeadline < policy.transportInactivity,
            "an interval re-armed by every byte cannot bound a body that arrives one byte at a time"
        )
    }
}
