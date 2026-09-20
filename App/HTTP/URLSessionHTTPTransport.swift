import Foundation

/// The real transport. **The only file in the app that mentions `URLSession`**, enforced
/// by a CI check — so any policy about how requests are made has exactly one place to
/// live, and a Provider cannot quietly acquire its own networking behaviour.
///
/// It does **no** retrying. Not on 429, not on 503, not on a dropped connection. A
/// chat completion is a POST that may already have been accepted, billed and answered by
/// the time the connection fails, so a resend here would be a second generation
/// presented to the user as the first. Retry belongs to a layer that knows about attempt
/// identity (`Agent Runtime.md:342`), and a transport that decided for itself would make
/// that decision unreachable.
///
/// That argument is sharper for a stream than for a single response. A stream that dies
/// partway has, by definition, already produced output — the notes forbid replaying the
/// whole request once that is true (`Agent Runtime.md:344`). This type reports that the
/// output existed and leaves the decision alone.
struct URLSessionHTTPTransport: HTTPTransport {
    let session: URLSession
    /// The transport reads the deadlines that are about the wire — `transportInactivity`
    /// and `errorBodyDeadline` — plus `checkInterval`, which is how often the liveness
    /// deadline is looked at. `firstEvent` and `betweenEvents` ask a question about the
    /// model, which a transport cannot answer. One policy value is passed to both layers
    /// rather than each holding its own copy of half of it.
    let timeouts: StreamTimeoutPolicy

    init(session: URLSession = .shared, timeouts: StreamTimeoutPolicy = .default) {
        self.session = session
        self.timeouts = timeouts
    }

    // MARK: - One response

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.urlRequest(from: request))
        } catch {
            // Scoped to the call itself. Wrapping the guards below in this `do` would
            // route their own `HTTPTransportError` back through the mapper, which would
            // rewrite a specific message into the generic "transport error".
            throw Self.transportError(from: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.networkFailure("the response was not HTTP")
        }
        return HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: data)
    }

    // MARK: - Incremental response

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: Self.urlRequest(
                from: request,
                // The request's own interval, not the session's. `URLSession` applies its
                // idle timer to the transfer, and the default is sixty seconds — which
                // would fire long before the liveness deadline below and report itself
                // as a dropped connection. Passing the policy down is what makes the
                // configured window the one that actually applies.
                timeout: timeouts.transportInactivity.timeInterval
            ))
        } catch {
            // The head never arrived, so this is not an interrupted stream — there was
            // no stream yet.
            throw Self.headError(from: error, timeouts: timeouts)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.networkFailure("the response was not HTTP")
        }

        guard (200..<300).contains(http.statusCode) else {
            // **Every exit from this branch ends the transfer**, including the throw at
            // the bottom. `bytes` carries the task that is actually doing the transfer,
            // and this branch is the one place that stops reading without ever handing
            // back an `HTTPStream` — so there is no cancel handle for a holder to call
            // and nothing else in the process that can end it. Leaving one exit without
            // this is how a refused request's connection outlives the interest in it.
            //
            // The scope is this branch, and that is not incidental. On the success path
            // `bytes.task` is the very transfer the returned `HTTPStream` reads through,
            // so this same line written one level out — outside the `guard` — would
            // cancel the stream the function is about to return. It is a one-line move
            // that silently breaks every successful request.
            defer { bytes.task.cancel() }

            // Bounded in space, like the parser's reassembly buffers. An error body is a
            // small JSON envelope; a server that sends megabytes must not be able to
            // grow this without limit.
            let read = ErrorBodyRead(limit: Self.maximumErrorBodyBytes)

            // A local, so the deadline task below captures a value rather than reaching
            // back through the transport for it — the same copy the success path makes
            // for its own escaping closures.
            let timeouts = self.timeouts

            // Bounded in time as well, and by a **total**: this fires once, a fixed
            // distance from now, and no byte moves it. The liveness window is the wrong
            // instrument here — every byte re-arms it, so a body arriving one byte at a
            // time never trips it, and the cap above bounds space rather than time.
            //
            // Deliberately **not** `StreamDeadline`, though it is the same shape and
            // would have been the obvious reuse. Its watchdog is a child task, so it
            // stands down as soon as the caller's task is cancelled — which is right for
            // a stream nobody is reading any more, and wrong here: a reader parked in a
            // socket read has to be released either way, and the caller's cancellation
            // is not reliably what releases it. Standing down would leave exactly the
            // case this deadline exists for with no deadline at all. Unstructured is the
            // point, not an oversight.
            let deadline = Task {
                try? await Task.sleep(for: timeouts.errorBodyDeadline)
                // `cancel()` from the `defer` below is the ordinary way this task ends.
                guard !Task.isCancelled else { return }
                // Recorded **before** the transfer is ended, and the order is the whole
                // argument. Ending it is how the reader is released, and what the reader
                // sees when that happens is a cancellation — so the fact has to be on
                // the record while the read is still running, or a body this deadline
                // gave up on would be reported as one that somebody walked away from.
                read.deadlineElapsed()
                // Releases a reader parked in a socket read, which nothing else can:
                // cancelling the reader's own task does not reliably reach `URLSession`.
                // The same reason `HTTPStream.cancel` exists.
                bytes.task.cancel()
            }
            // Ends the deadline task on every other exit, so a read that finished on its
            // own does not leave a task sitting on this deadline for the rest of it.
            defer { deadline.cancel() }

            do {
                for try await byte in bytes {
                    // `false` means the cap was reached. Breaking is not "stop waiting
                    // for this byte" — it is "this body is no longer wanted", and the
                    // transfer has to be ended either way.
                    guard read.append(byte) else { break }
                }
            } catch {
                read.record(error)
            }

            let outcome = read.outcome
            // A caller who walked away is answered first, because that is the one fact
            // here about the **caller** rather than about the body.
            //
            // It sits above the other two on purpose, and the routes it closes are real
            // rather than theoretical. Expiring is how the deadline releases its reader,
            // so a slow 401 would otherwise come back as an expiry — and an expiry
            // carries the response, whose status is what marks the credential rejected.
            // A cancellation arriving on its own is not reliably a *thrown* cancellation
            // either: measured in `StreamingCancellationTests`, it can end the body
            // cleanly, and a clean end reports the status just the same.
            //
            // So no route out of this branch may turn "the user pressed Stop" into a
            // verdict about their credential. That status→error mapping is not a message
            // — `credentialRejected` is what the availability judgement reads — and a
            // cancellation is not evidence about a credential.
            if Task.isCancelled { throw HTTPTransportError.cancelled }
            // Then the deadline, before the reader's own failure. Expiring releases the
            // reader by ending the transfer, which the reader reports as a cancellation
            // — so checking that first would turn every expired deadline into a Stop.
            if case .deadlineElapsed = outcome {
                throw HTTPTransportError.errorBodyTimeout(
                    HTTPResponse(
                        status: http.statusCode,
                        headers: Self.headers(from: http),
                        body: outcome.body
                    ),
                    after: timeouts.errorBodyDeadline
                )
            }
            // Cancellation is not a refusal. Swallowing it here would report a streamed
            // 401 to someone who pressed Stop as "your credential was rejected" — the
            // exact inversion of what cancellation reporting is for. Reached when the
            // transfer was ended by something other than this call being cancelled:
            // tearing the session down, for one.
            if case .failed(_, let error) = outcome, Self.isCancellation(error) {
                throw HTTPTransportError.cancelled
            }
            // The status line arrived before the failure, so the status is known even
            // when the body is not. Reporting it with a partial body is more useful than
            // reporting a network failure: a 401 is a 401, and the absence of readable
            // diagnostic text is already a case the error mapping handles.
            throw HTTPTransportError.httpStatus(
                HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: outcome.body)
            )
        }

        // Rearmed by every byte, including the bytes of a keep-alive comment. That is
        // the question this deadline asks: whether the connection is alive. Whether the
        // model is producing is a different question, asked a layer up.
        let progress = StreamProgress()
        let timeouts = self.timeouts

        // The handle that makes cancellation explicit. `AsyncBytes` carries the task that
        // is actually doing the transfer, so ending the transfer is one call — not a
        // chain of hopes that cancelling one Task ends a stream, whose termination
        // cancels another Task, whose cancellation reaches URLSession.
        let networkTask = bytes.task

        return HTTPStream(
            body: AsyncThrowingStream { continuation in
            // **Best-effort cleanup, not the guarantee.** This catches the ways a
            // stream ends that the holder cannot see: the body being dropped, or
            // finished by a deadline or a parse failure.
            //
            // It is deliberately not the correctness story. Cancelling a consuming task
            // does not reliably arrive here — CI showed the network task surviving a
            // cancelled consumer — so a layer that *needs* the transfer stopped must
            // call `HTTPStream.cancel` rather than expect this to notice on its behalf.
            // Anyone reading this as "the explicit handle is redundant" has it
            // backwards: this is the half that cannot be relied on.
            continuation.onTermination = { _ in networkTask.cancel() }

            Task {
                await StreamDeadline.run(
                    progress: progress,
                    first: timeouts.transportInactivity,
                    subsequent: timeouts.transportInactivity,
                    checkInterval: timeouts.checkInterval,
                    onTimeout: { elapsed in
                        // Ending the stream cancels the reader below, which is the only
                        // way a read blocked on a silent socket ever lets go.
                        continuation.finish(
                            throwing: HTTPTransportError.inactivityTimeout(after: elapsed.after)
                        )
                    },
                    reading: {
                        do {
                            for try await byte in bytes {
                                // Records both that this byte arrived and that the
                                // liveness deadline restarts here. `hasAdvanced` is the
                                // same fact the layer above needs to tell "the model
                                // never started" from "the answer was cut off" — a fact
                                // about what the server sent, not about whether the
                                // consumer has caught up.
                                progress.advanced()
                                // One byte per element rather than a batched chunk.
                                // Batching would trade latency for throughput, and the
                                // wrong way round: this is text from a language model,
                                // kilobytes spread over seconds, where arriving
                                // immediately is the whole point and the allocation cost
                                // is nothing beside it.
                                continuation.yield(Data([byte]))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(
                                throwing: Self.streamError(
                                    from: error,
                                    deliveredData: progress.hasAdvanced,
                                    timeouts: timeouts
                                )
                            )
                        }
                    }
                )
            }
            },
            // The same call, exposed. A holder that stops caring — because it is
            // stopping a run, because a deadline expired, because it decoded something it
            // could not trust — ends the transfer here rather than waiting to find out
            // whether its own termination propagated.
            //
            // Leaving this uncalled is how a connection outlives the interest in it:
            // `Agent Runtime.md:261` — a late result still arriving after the run it
            // belonged to was stopped.
            cancel: { networkTask.cancel() }
        )
    }

    // MARK: - A refused response's body

    /// The most of an error body worth keeping. Far above any real envelope.
    private static let maximumErrorBodyBytes = 64 << 10

    /// Why a refused response's body stopped being read.
    ///
    /// Three ways, and two of them are worth telling apart. `.ended` covers both "the
    /// body finished" and "the cap was reached" — from inside the loop those are the
    /// same event, a read that ran to its own end, and neither is a failure: the status
    /// is known either way. `.failed` is the connection giving out, and
    /// `.deadlineElapsed` is this transport giving up, which is a different thing
    /// entirely and the reason the case exists.
    private enum ErrorBodyOutcome {
        case ended(Data)
        case failed(Data, Error)
        case deadlineElapsed(Data)

        /// Whatever arrived — the whole envelope, or as much of one as there was. A
        /// partial body is still worth reporting: it is where the diagnostic message
        /// comes from, and "no readable text" is already a case the error mapping
        /// handles.
        var body: Data {
            switch self {
            case .ended(let body), .failed(let body, _), .deadlineElapsed(let body):
                return body
            }
        }
    }

    /// The bounded read of a refused response's body, and the one answer it produces.
    ///
    /// Lock-protected for the reason `StreamProgress` is: a reader and a deadline run
    /// concurrently, and the outcome has to be a single value rather than three facts
    /// that can be read in an order that makes them disagree. `deadlineElapsed` is
    /// recorded before the transfer is ended, so the reader's own failure — a
    /// cancellation, because that is what ending the transfer looks like from inside —
    /// never becomes the report.
    private final class ErrorBodyRead: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var failure: Error?
        private var expired = false

        init(limit: Int) { self.limit = limit }

        /// Appends a byte, or reports that the cap has been reached.
        func append(_ byte: UInt8) -> Bool {
            lock.withLock {
                guard data.count < limit else { return false }
                data.append(byte)
                return true
            }
        }

        func record(_ error: Error) { lock.withLock { failure = error } }

        func deadlineElapsed() { lock.withLock { expired = true } }

        /// Decided in one locked read, for the same reason `elapsedDeadline` is: the
        /// precedence between the deadline and the reader's failure is part of the
        /// answer, not something a caller should be able to re-derive in the other order.
        var outcome: ErrorBodyOutcome {
            lock.withLock {
                if expired { return .deadlineElapsed(data) }
                if let failure { return .failed(data, failure) }
                return .ended(data)
            }
        }
    }

    // MARK: - Request building

    private static func urlRequest(from request: HTTPRequest, timeout: TimeInterval? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        if let timeout { urlRequest.timeoutInterval = timeout }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }

    // MARK: - Failure mapping

    /// Everything that can go wrong with a request, in transport terms.
    ///
    /// Cancellation is checked first and kept separate from failure on purpose. A
    /// cancelled request is not a request that went wrong — reporting it as one would
    /// put an error in front of someone who pressed Stop, and would make "the user
    /// stopped this" indistinguishable from "this broke".
    private static func transportError(from error: Error) -> HTTPTransportError {
        if isCancellation(error) { return .cancelled }
        // The error's own description, never the request's. `URLError` carries the
        // failing URL and a code; a message built from the request would carry the
        // Authorization header, and this string ends up in logs.
        return .networkFailure(describe(error))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// A failure before the response head, for a streaming request.
    ///
    /// A timeout here is the same event the liveness deadline describes, arriving by way
    /// of `URLSession`'s own idle timer. Reporting it as a network failure would tell
    /// someone their connection dropped when in fact nothing was sent for a while — the
    /// conflation `HTTPTransportError.inactivityTimeout` exists to prevent.
    private static func headError(from error: Error, timeouts: StreamTimeoutPolicy) -> HTTPTransportError {
        if (error as? URLError)?.code == .timedOut {
            return .inactivityTimeout(after: timeouts.transportInactivity)
        }
        return transportError(from: error)
    }

    /// The same mapping, with the one difference a stream introduces.
    ///
    /// A failure that arrives before the head is a failed request; one that arrives
    /// after it is an interrupted stream, and the caller needs to know which bytes had
    /// already been handed over.
    private static func streamError(
        from error: Error,
        deliveredData: Bool,
        timeouts: StreamTimeoutPolicy
    ) -> HTTPTransportError {
        if (error as? URLError)?.code == .timedOut {
            return .inactivityTimeout(after: timeouts.transportInactivity)
        }
        let mapped = transportError(from: error)
        guard case .networkFailure(let reason) = mapped else { return mapped }
        return .streamInterrupted(deliveredData: deliveredData, reason: reason)
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "transport error"
        }
        // Deliberately not `urlError.localizedDescription` verbatim either: it is stable
        // enough, but the code is the part worth keeping, and the code is safe.
        return "URLError code \(urlError.errorCode)"
    }
}
