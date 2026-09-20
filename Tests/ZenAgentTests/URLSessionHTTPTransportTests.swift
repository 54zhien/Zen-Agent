import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **the real transport delivers a stream, and says honestly how it
/// ended.**
///
/// Every test here drives the actual `URLSessionHTTPTransport` — the same code the app
/// runs — against a scripted `URLProtocol`. Nothing stands in for the type under test.
///
/// That matters most for the things a fake cannot reproduce: a body that arrives in
/// pieces over time, a connection that stops without saying so, and a cancellation that
/// either does or does not reach the underlying task. A fake can claim all three; only
/// this can show them.
@Suite("URLSession HTTP transport")
struct URLSessionHTTPTransportTests {

    // MARK: - Fixture

    /// A URL unique to the calling test, so scripts never collide across the parallel
    /// suites sharing `StubURLProtocol`'s registry.
    private func makeURL() -> URL {
        URL(string: "https://stub-\(UUID().uuidString).invalid/chat/completions")!
    }

    private func makeTransport() -> URLSessionHTTPTransport {
        URLSessionHTTPTransport(session: StubURLProtocol.makeSession())
    }

    private func post(_ url: URL) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: url,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"stream":true}"#.utf8)
        )
    }

    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var received = Data()
        for try await chunk in stream { received.append(chunk) }
        return received
    }

    private func text(_ stream: AsyncThrowingStream<Data, Error>) async throws -> String {
        String(decoding: try await drain(stream), as: UTF8.self)
    }

    // MARK: - One response

    @Test("send returns the status, headers and body")
    func sendReturnsTheResponse() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script.delivering([#"{"id":"chat-1"}"#])
        script.status = 200
        script.headers = ["Content-Type": "application/json"]
        StubURLProtocol.register(script, for: url)

        let response = try await makeTransport().send(post(url))

        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"id":"chat-1"}"#)
        #expect(response.headers["Content-Type"] == "application/json")
    }

    @Test("send reports a connection that never reached a server")
    func sendReportsNetworkFailure() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        script.headFailureCode = .cannotConnectToHost
        StubURLProtocol.register(script, for: url)

        var failure: Error?
        do {
            _ = try await makeTransport().send(post(url))
        } catch {
            failure = error
        }

        guard let transportError = failure as? HTTPTransportError,
              case .networkFailure = transportError else {
            Issue.record("expected .networkFailure, got \(String(describing: failure))")
            return
        }
    }

    // MARK: - Streaming

    @Test("stream delivers the body in the order the server sent it")
    func streamDeliversInOrder() async throws {
        let url = makeURL()
        StubURLProtocol.register(
            .delivering(["data: one\n\n", "data: two\n\n", "data: [DONE]\n\n"]),
            for: url
        )

        let body = try await text(makeTransport().stream(post(url)).body)

        #expect(body == "data: one\n\ndata: two\n\ndata: [DONE]\n\n")
    }

    @Test("a body arriving in many small pieces is delivered whole")
    func streamReassemblesAcrossDeliveries() async throws {
        let url = makeURL()
        // One byte per delivery, which is the least the network could possibly do.
        let pieces = Array("data: hello\n\n").map { String($0) }
        StubURLProtocol.register(.delivering(pieces), for: url)

        let body = try await text(makeTransport().stream(post(url)).body)

        #expect(body == "data: hello\n\n")
    }

    @Test("a non-2xx status is thrown, not streamed, and carries the body")
    func nonSuccessStatusThrows() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script.delivering([#"{"error":{"message":"Authentication Fails"}}"#])
        script.status = 401
        StubURLProtocol.register(script, for: url)

        var failure: Error?
        do {
            let stream = try await makeTransport().stream(post(url)).body
            _ = try await drain(stream)
        } catch {
            failure = error
        }

        guard let transportError = failure as? HTTPTransportError,
              case .httpStatus(let response) = transportError else {
            Issue.record("expected .httpStatus, got \(String(describing: failure))")
            return
        }
        #expect(response.status == 401)
        #expect(
            String(decoding: response.body, as: UTF8.self).contains("Authentication Fails"),
            "the error body must survive — it is what the diagnostic message is built from"
        )
    }

    @Test("a connection that dies before the status line is a network failure")
    func failureBeforeTheHead() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        script.headFailureCode = .networkConnectionLost
        StubURLProtocol.register(script, for: url)

        var failure: Error?
        do {
            _ = try await makeTransport().stream(post(url)).body
        } catch {
            failure = error
        }

        // Nothing had been streamed, because there was never a stream.
        guard let transportError = failure as? HTTPTransportError,
              case .networkFailure = transportError else {
            Issue.record("expected .networkFailure, got \(String(describing: failure))")
            return
        }
    }

    /// Restored onto a real local socket. It was disabled because a scripted
    /// `URLProtocol` cannot deliver a small body and then stall — characterised in
    /// `URLProtocolCharacterisationTests`, where a single `didLoad` with the request left
    /// open never reached the consumer at all.
    ///
    /// The close has to be **abortive**. A graceful one is measured to arrive at
    /// `bytes(for:)` as a clean end, and a clean end is not a throwing failure, so it
    /// cannot produce the condition this test asserts. `.chunkThenAbort` sends RST — and
    /// that capability is characterised on its own before anything here relies on it.
    @Test("a connection that dies after data was observed is an interrupted stream that delivered data")
    func failureAfterObservedDataIsInterrupted() async throws {
        let partial = "data: partial ans"
        let server = try LocalHTTPServer(script: .chunkThenAbort(partial))
        server.start()
        defer { server.shutdown() }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(session: session)
        let url = server.baseURL.appending(path: "chat/completions")

        var failure: Error?
        var received = Data()
        var closureRequested = false
        do {
            for try await chunk in try await transport.stream(post(url)).body {
                received.append(chunk)
                // Ask for the abort only once the **complete** intended body is in hand.
                // That is what makes "the transport had observed data before the failure"
                // caused rather than hoped for: nothing here waits, and nothing races.
                if !closureRequested, String(decoding: received, as: UTF8.self) == partial {
                    closureRequested = true
                    server.requestClose()
                }
            }
        } catch {
            failure = error
        }

        guard let transportError = failure as? HTTPTransportError,
              case .streamInterrupted(let deliveredData, _) = transportError else {
            Issue.record("expected .streamInterrupted, got \(String(describing: failure))")
            return
        }
        #expect(
            deliveredData,
            "the server had already produced output, which is the fact that forbids replaying the request"
        )
        #expect(
            String(decoding: received, as: UTF8.self) == partial,
            "whatever arrived before the failure is the caller's to keep"
        )
        #expect(server.wroteChunk, "the server never wrote its partial body")
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
    }

    // MARK: - A refused response's body

    /// Product invariant: **the body of a refused response is bounded in time as well as
    /// in space, and the connection carrying it is ended either way.**
    ///
    /// These are the one branch that reads a response without ever producing a stream, so
    /// they are the one branch where `HTTPStream.cancel` cannot help: no handle is handed
    /// back, and the caller that would have called it gets a thrown error instead. If this
    /// branch does not end its own transfer, nothing in the process can.

    /// How a refusal ended.
    private enum Refusal: Sendable {
        case threw(HTTPTransportError)
        case threwSomethingElse
        case returnedWithoutThrowing
        /// The bound expired with the call still running — the state an endless error
        /// body produced before the absolute deadline existed, and the one both tests
        /// below are written to catch.
        case neverReturned
    }

    /// The outcome of a call that has to be given a bound.
    private final class BoundedCall: @unchecked Sendable {
        private let lock = NSLock()
        private var finished: Refusal?

        func record(_ outcome: Refusal) { lock.withLock { finished = outcome } }
        var outcome: Refusal? { lock.withLock { finished } }
    }

    /// Deadlines for the refusal tests.
    ///
    /// The liveness window is deliberately many times the trickle interval in the second
    /// test, so it can never be the thing that ends that read. That is the point being
    /// made: a window re-armed by every byte cannot end an endless body, and if this one
    /// fired the error would name a different deadline and the assertion would say so.
    private func refusalPolicy(errorBodyDeadline: Duration) -> StreamTimeoutPolicy {
        StreamTimeoutPolicy(
            transportInactivity: .seconds(4),
            errorBodyDeadline: errorBodyDeadline,
            firstEvent: .seconds(30),
            betweenEvents: .seconds(30),
            checkInterval: .milliseconds(20)
        )
    }

    /// Runs a refusal and reports how it ended, giving up after a bound.
    private func awaitRefusal(
        _ transport: URLSessionHTTPTransport,
        _ url: URL,
        attempts: Int = 800
    ) async -> Refusal {
        let call = BoundedCall()
        Task {
            do {
                _ = try await transport.stream(post(url))
                call.record(.returnedWithoutThrowing)
            } catch let error as HTTPTransportError {
                call.record(.threw(error))
            } catch {
                call.record(.threwSomethingElse)
            }
        }

        return await awaitOutcome(call, attempts: attempts)
    }

    /// Waits out a call that has to be given a bound, and reports how it ended.
    ///
    /// **Bounded because the failure under test is a call that never returns**, and a
    /// test that hangs reports nothing — it takes the host with it, and the runner's
    /// log then says "Restarting after unexpected exit" instead of naming the test. The
    /// bound is a guard against that, not a performance budget: the deadlines under test
    /// are milliseconds and this is seconds, so nothing here is close to it.
    ///
    /// Separate from `awaitRefusal` because one caller has to cancel the call itself and
    /// so has to hold its `Task`, which `awaitRefusal` does not give back. Sharing this
    /// loop is what keeps the two callers from disagreeing about *how an outcome wait
    /// ends* — the fact they have in common. It does not pool the per-fact polls below:
    /// those wait on the server (`wroteChunk`, `observedPeerClose`) rather than on this
    /// box, and each states its own bound at its use site.
    ///
    /// A call still running when the bound expires is left to the caller's teardown.
    /// Cancelling it would achieve nothing — cancelling a consumer does not reliably
    /// reach `URLSession`, which is the fact this suite is built on — so the session's
    /// `invalidateAndCancel` and the server's `shutdown` are what release it.
    private func awaitOutcome(_ call: BoundedCall, attempts: Int) async -> Refusal {
        for _ in 0..<attempts where call.outcome == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Waited for, never asserted on: the fact is the outcome, and a bounded wait that
        // always passed would be worse than no bound at all.
        return call.outcome ?? .neverReturned
    }

    @Test("a refused body is capped, and reaching the cap ends the transfer")
    func nonSuccessBodyIsCappedAndEndsTheTransfer() async throws {
        // 4 KiB per write with no pause, for as long as the socket allows. The cap is
        // reached in milliseconds; the server is only ever told to keep writing.
        let server = try LocalHTTPServer(
            script: .continuous(String(repeating: "x", count: 4096), every: 0.001),
            status: 401
        )
        server.start()
        defer { server.shutdown() }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // A deadline far out, so the cap is provably what stopped the read — and so that
        // a failure here cannot be the other mechanism's. The error case says which one
        // fired, and this asserts on that rather than on a clock.
        let transport = URLSessionHTTPTransport(
            session: session,
            timeouts: refusalPolicy(errorBodyDeadline: .seconds(10))
        )

        let outcome = await awaitRefusal(transport, server.baseURL.appending(path: "chat/completions"))

        guard case .threw(.httpStatus(let response)) = outcome else {
            Issue.record("expected .httpStatus, got \(String(describing: outcome))")
            return
        }
        #expect(response.status == 401)
        // **Exactly** the cap, not merely under it. The 65,536th byte is stored and is the
        // last one this transport was ever going to keep, so an exact count is what shows
        // the cap is the thing that stopped the read. `<=` would also pass for a read that
        // stopped early for some other reason, which is a different bug wearing the same
        // symptom.
        #expect(
            response.body.count == 64 << 10,
            """
            the envelope kept has to be exactly the documented cap: the cap is what proves \
            this read stopped because the body was too big rather than because something \
            else ended it; got \(response.body.count) bytes
            """
        )
        // And it is the **first** 64 KiB of what the server sent, in order. A read that
        // kept the last 64 KiB, or that dropped a byte at the boundary, would satisfy a
        // count and fail this.
        #expect(
            response.body == Data(repeating: UInt8(ascii: "x"), count: 64 << 10),
            "the bytes kept must be the ones the server actually sent, from the start"
        )
        #expect(server.wroteChunk, "the server never wrote its body")

        // **The server's own observation, which is the only thing that can report this.**
        // The throw happens before any cancel does — this branch throws whether or not
        // the transfer was ended — so asserting on the error says nothing about the
        // connection. A client that stops reading while the peer keeps writing is exactly
        // the failure being tested for, and only the peer can see it.
        //
        // This is a **resource-ownership** regression test, and it is deliberately not
        // phrased as "the previous implementation must fail here". Whether Foundation
        // closes a connection once the `AsyncBytes` reference goes away is not something
        // this suite has characterised, and it may well close one by luck — in which case
        // a broken implementation would pass. What is asserted is the end state a holder
        // can rely on: a client that stopped reading at the cap did not leave the peer
        // writing into a live connection.
        for _ in 0..<800 where !server.observedPeerClose {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.observedPeerClose,
            """
            the cap stopped the read and left the transfer running. 64 KiB is a reason to \
            stop reading a body; it is not a reason to keep the connection that is \
            carrying it
            """
        )
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
    }

    @Test("a refused body that trickles forever still ends, and ends the transfer")
    func nonSuccessBodyTricklingForeverEndsAtTheAbsoluteDeadline() async throws {
        // One byte every 300ms, forever. `transportInactivity` is 4s, so the gap the
        // liveness window watches is never more than a thirteenth of it — that window is
        // re-armed by every byte and can never fire. Nor is the 64 KiB cap in reach: at
        // this rate it is hours away. The only thing that can end this read is a deadline
        // counted from the **start** of it, which is what the field being tested is.
        let server = try LocalHTTPServer(script: .continuous(".", every: 0.3), status: 503)
        server.start()
        defer { server.shutdown() }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(
            session: session,
            timeouts: refusalPolicy(errorBodyDeadline: .milliseconds(900))
        )

        let outcome = await awaitRefusal(transport, server.baseURL.appending(path: "chat/completions"))

        // The case is the assertion that matters. An expiry releases the reader by ending
        // the transfer, which the reader sees as a cancellation — so a transport that
        // reported the mechanism instead of the reason would land on `.cancelled` here,
        // and one that reported the *other* deadline would land on `.inactivityTimeout`.
        // Neither is this, and `neverReturned` is what the code did before the absolute
        // deadline existed.
        guard case .threw(.errorBodyTimeout(let response, let after)) = outcome else {
            Issue.record(
                """
                expected .errorBodyTimeout, got \(String(describing: outcome)). A body \
                that never finishes arriving has to be given up on, and the report has to \
                say which deadline said so: "the connection died" and "the body was not \
                worth waiting for" send someone to look in opposite places
                """
            )
            return
        }
        #expect(response.status == 503, "the status line arrived before the body did")
        // The **configured** deadline, reported by the mechanism that fired — not a
        // measurement of the wall clock. Which deadline the error names is the fact a
        // caller acts on, and it stays true on a loaded CI machine where releasing the
        // read itself may take noticeably longer than the deadline did to elapse.
        #expect(
            after == .milliseconds(900),
            "the error must name the deadline that fired, got \(after)"
        )

        for _ in 0..<800 where !server.observedPeerClose {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.observedPeerClose,
            "the deadline ended the read and left the transfer running"
        )
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
    }

    /// The same refusal, ended by the **caller** rather than by any deadline.
    ///
    /// This is the one route through the refusal branch that neither of the tests above
    /// can stand in for. Ending the transfer is how a deadline releases its reader, so
    /// "this deadline expired" and "the caller pressed Stop" arrive at the reader as the
    /// same event — and the two must not be confused, because one of them is a verdict
    /// about the credential and the other is a decision the caller already made. The
    /// transport's ordering is what keeps them apart, and this drives it through a real
    /// socket rather than through a stub that could only claim to have.
    @Test("a caller who cancels while a refused body is draining is answered with .cancelled")
    func cancellingDuringARefusalBodyIsCancelled() async throws {
        // The same slow trickle the deadline test uses, and for the same reason: a byte
        // every 300ms never finishes the body, so the read is still in progress whenever
        // the cancellation lands, and 64 KiB is hours away.
        //
        // **401, not 503.** It is the status whose mapping is `credentialRejected`, so a
        // transport that let the known status win over the caller's decision would be
        // caught by the case assertion below rather than passing quietly.
        let server = try LocalHTTPServer(script: .continuous(".", every: 0.3), status: 401)
        server.start()
        defer { server.shutdown() }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Thirty seconds, so the deadline provably cannot be what ends this read. A body
        // this test gave up on by itself would say nothing about the ordering under test.
        let transport = URLSessionHTTPTransport(
            session: session,
            timeouts: refusalPolicy(errorBodyDeadline: .seconds(30))
        )

        let call = BoundedCall()
        let task = Task {
            do {
                _ = try await transport.stream(post(server.baseURL.appending(path: "chat/completions")))
                call.record(.returnedWithoutThrowing)
            } catch let error as HTTPTransportError {
                call.record(.threw(error))
            } catch {
                call.record(.threwSomethingElse)
            }
        }

        // **The barrier, and it is the test's soundness rather than a courtesy.** The
        // server writes the head before it writes any body, so once a body byte exists the
        // client is past "waiting for a response" and into the refusal branch — that is
        // what makes this a test of draining a refused body rather than of cancelling a
        // request whose response never arrived. The wait is bounded and asserted on, so a
        // server that never got that far fails loudly instead of passing vacuously.
        for _ in 0..<800 where !server.wroteChunk {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.wroteChunk,
            "the server never wrote the first body byte, so nothing was draining and nothing was tested"
        )

        task.cancel()

        // Bounded to roughly three seconds: this call has to return, and one that does
        // not is the failure, not a slow success.
        let outcome = await awaitOutcome(call, attempts: 300)
        guard case .threw(let error) = outcome else {
            Issue.record(
                """
                expected the call to end as a thrown HTTPTransportError, got \
                \(String(describing: outcome)). A caller who cancelled is not waiting for \
                this body, and the refusal branch has to let go of it
                """
            )
            return
        }
        // The case, and it excludes both of the other two by name. `.httpStatus` would
        // carry the 401 up into a `credentialRejected` verdict about someone who pressed
        // Stop; `.errorBodyTimeout` would blame a deadline that had thirty seconds left.
        guard case .cancelled = error else {
            Issue.record(
                "expected .cancelled, got \(error) — a cancellation is not evidence about a credential"
            )
            return
        }

        // Asserted **before** `session.invalidateAndCancel()` runs, so the close cannot
        // be the teardown's doing. Same bounded wait the tests above use, for the same
        // reason: the fact belongs to the peer, which only reports it when its next write
        // fails.
        for _ in 0..<800 where !server.observedPeerClose {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.observedPeerClose,
            """
            the cancellation answered the caller and left the transfer running. Nobody is \
            waiting for this response any more, and no stream handle was handed back — so \
            if this branch does not end the transfer, nothing does
            """
        )
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
    }

    @Test("a connection that dies before delivering anything is a failed request, not an interruption")
    func failureBeforeDataIsAFailedRequest() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        script.failureCode = .networkConnectionLost
        StubURLProtocol.register(script, for: url)

        var failure: Error?
        do {
            for try await _ in try await makeTransport().stream(post(url)).body {}
        } catch {
            failure = error
        }

        // This assertion started out expecting `.streamInterrupted(deliveredData: false)`
        // and was wrong. With no body byte ever delivered, `bytes(for:)` itself throws —
        // there is no stream for the transport to have observed ending. `.networkFailure`
        // is the honest report.
        //
        // And it is the distinction the notes ask for (`Provider 与模型.md:66`), just
        // drawn where the transport can actually see it: nothing delivered ends as a
        // failed request, and the same failure after output exists ends as an interrupted
        // stream. Those two carry different `RetryDisposition`s, which is the whole point
        // — nothing delivered may still be retried if a higher layer can prove the
        // request was never accepted; output already delivered may not be replayed.
        guard let transportError = failure as? HTTPTransportError,
              case .networkFailure = transportError else {
            Issue.record("expected .networkFailure, got \(String(describing: failure))")
            return
        }
    }

    // MARK: - No retry

    @Test("a failed stream makes exactly one request")
    func failedStreamDoesNotRetry() async throws {
        let url = makeURL()
        // A second response is queued behind the failure, so a transport that retried
        // would find one and appear to succeed — which is how a hidden retry slips past.
        var script = StubURLProtocol.Script.delivering(["data: x"])
        script.failureCode = .networkConnectionLost
        StubURLProtocol.register(script, for: url)

        _ = try? await drain(try await makeTransport().stream(post(url)).body)

        #expect(
            StubURLProtocol.requestCount(for: url) == 1,
            """
            expected one attempt, made \(StubURLProtocol.requestCount(for: url)). \
            Re-sending a streaming POST asks the model to generate the answer again \
            while the caller still believes it is the same answer (Agent Runtime.md:344).
            """
        )
    }
}
