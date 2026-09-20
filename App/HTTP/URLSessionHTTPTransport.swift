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
            // Cancelled **here**, in the guard, and nowhere wider. This response is not
            // one the branch below will handle, so nothing else in the function is
            // going to end the transfer — the same "no owner" situation the refusal
            // branch handles for itself. Writing it as a function-level `defer` instead
            // would be the one-line move that cancels the successful stream this
            // function is about to hand back.
            bytes.task.cancel()
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
            // Three owners, one per shape of response, and none of them overlaps:
            //
            // - a **non-HTTP** response is cancelled inside its own guard, above;
            // - **this branch** ends its transfer in a local `defer`, which is the only
            //   thing covering all of its exits;
            // - a **2xx** hands `bytes.task` to the returned `HTTPStream`, which owns it
            //   from then on.
            //
            // The scope of this line is therefore not incidental. On the success path
            // `bytes.task` is the very transfer the returned `HTTPStream` reads through,
            // so this same line written one level out — outside the `guard` — would
            // cancel the stream the function is about to return. It is a one-line move
            // that silently breaks every successful request.
            let networkTask = bytes.task
            defer { networkTask.cancel() }

            // Bounded in space, like the parser's reassembly buffers. An error body is a
            // small JSON envelope; a server that sends megabytes must not be able to
            // grow this without limit.
            let read = ErrorBodyRead(limit: Self.maximumErrorBodyBytes)

            // A local, so the deadline task below captures a value rather than reaching
            // back through the transport for it — the same copy the success path makes
            // for its own escaping closures.
            let errorBodyDeadline = self.timeouts.errorBodyDeadline

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
            let deadlineTask: Task<Void, Never> = Task {
                do {
                    try await Task.sleep(for: errorBodyDeadline)
                } catch {
                    // The branch exited before the deadline did, and the `defer` below
                    // withdrew this watchdog. Nothing to report and nothing to end.
                    return
                }

                // **Only the first terminal state gets to act.** Ending the transfer is
                // the deadline's one piece of authority, and it may only be exercised by
                // winning the transition into `.deadlineElapsed` — which it cannot do if
                // the read already committed `.ended`, `.capped` or `.failed`. Without
                // that, this wake-up would cancel a transfer that had finished perfectly
                // well on its own, and the caller would be told a body had timed out
                // after reading all of it.
                if read.markDeadlineElapsed() {
                    // Releases a reader parked in a socket read, which nothing else can:
                    // cancelling the reader's own task does not reliably reach
                    // `URLSession`. The same reason `HTTPStream.cancel` exists.
                    networkTask.cancel()
                }
            }
            // Ends the deadline task on every other exit, so a read that finished on its
            // own does not leave a task sitting on this deadline for the rest of it.
            //
            // Written after `networkTask`'s `defer` above, so the two run in reverse:
            // this one first, with the watchdog withdrawn before the transfer is ended.
            // That ordering is tidiness rather than the guarantee — a watchdog waking in
            // the gap would find a terminal state already committed and decline to act,
            // which is the state machine doing the work. It just keeps the ordinary exit
            // from looking, in order of events, like a deadline that fired.
            defer { deadlineTask.cancel() }

            do {
                for try await byte in bytes {
                    // Answered before the byte is considered, because a caller who has
                    // walked away is not waiting for it. Without this the loop would run
                    // to whatever end the server chose — the cap, or an endless trickle
                    // held open until the deadline — and report the body's fate instead
                    // of the caller's decision.
                    try Task.checkCancellation()
                    // `false` means the cap was reached, and the cap is committed as a
                    // terminal state inside `append` rather than after it: returning
                    // first would leave a window in which the deadline could win a race
                    // it should have lost.
                    guard read.append(byte) else { break }
                }

                // Natural EOF. `append` has already committed the cap for itself, and
                // this call is a no-op if it did — or if a failure got here first.
                read.end()
            } catch {
                // Ignored when a terminal state was already committed, which is the
                // whole point: ending the transfer is how the deadline releases its
                // reader, so the reader's own report of that is a cancellation, and a
                // cancellation must not overwrite the fact that this transport gave up
                // on a body. Same the other way round — a read that failed on its own
                // keeps its failure against a deadline that never fired.
                read.fail(error)
            }

            let snapshot = read.snapshot()
            // A caller who walked away is answered first, because that is the one fact
            // here about the **caller** rather than about the body.
            //
            // It sits above the others on purpose, and the routes it closes are real
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

            // One construction, used by both throws below. The status line arrived
            // before the body did, so the status is known either way; what varies is how
            // much of the diagnostic text came with it, and both exits report as much as
            // there was.
            let response = HTTPResponse(
                status: http.statusCode,
                headers: Self.headers(from: http),
                body: snapshot.body
            )

            switch snapshot.state {
            case .deadlineElapsed:
                // Before the reader's own failure, because expiring *is* how the reader
                // was released — it reports that as a cancellation, and reading its
                // failure first would turn every expired deadline into a Stop.
                throw HTTPTransportError.errorBodyTimeout(response, after: errorBodyDeadline)

            case .failed(let error):
                // Cancellation is not a refusal. Swallowing it here would report a
                // streamed 401 to someone who pressed Stop as "your credential was
                // rejected" — the exact inversion of what cancellation reporting is for.
                // Reached when the transfer was ended by something other than this call
                // being cancelled: tearing the session down, for one.
                if Self.isCancellation(error) { throw HTTPTransportError.cancelled }

                // Any other read error still reports the status, with whatever body got
                // through: a 401 is a 401, and the absence of readable diagnostic text is
                // already a case the error mapping handles.
                throw HTTPTransportError.httpStatus(response)

            case .ended, .capped:
                // The status is known and the body is as complete as this transport was
                // ever going to make it. Neither is a failure.
                throw HTTPTransportError.httpStatus(response)

            case .reading:
                // `snapshot()` refuses to produce this.
                preconditionFailure("unreachable after snapshot()")
            }
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

    /// The bounded read of a refused response's body, and the one state it comes to rest
    /// in.
    ///
    /// Lock-protected for the reason `StreamProgress` is: a reader and a deadline run
    /// concurrently, and the answer has to be a single value rather than several facts
    /// that can be read in an order that makes them disagree.
    ///
    /// **First terminal state wins, and that is the whole mechanism.** The reader and the
    /// deadline are two independent parties that can each decide this read is over, and
    /// they race. A design where the deadline sets a flag of its own and cancels the
    /// transfer unconditionally has no way to tell "I gave up on this body" from "the
    /// body had already finished and I am cancelling the connection afterwards" — the
    /// reader could have committed `.ended` microseconds earlier, and the report would
    /// still say the body timed out. So neither party writes an outcome directly: both
    /// **transition out of `.reading`**, and the loser of that transition learns it lost
    /// and does nothing else. Only the deadline's transition carries the extra authority
    /// to end the transfer, and it may only exercise that by winning.
    ///
    /// The four terminal states are the four ways the read can honestly end:
    ///
    /// - `.ended` — the server finished the body. **Natural EOF only**; reaching the
    ///   local cap is a separate state rather than folded in here, because "the server
    ///   said it was done" and "this transport stopped listening" are different facts
    ///   about the response even though both leave the status usable.
    /// - `.capped` — the 65,536th byte was written. Committed inside `append`, in the
    ///   same critical section as that byte, so there is no window between storing the
    ///   byte and recording why the loop is about to stop.
    /// - `.failed` — the connection gave out. The reader's own error, kept rather than
    ///   resolved, because whether it is a cancellation or a real failure is a question
    ///   for the caller of this branch, not for this type.
    /// - `.deadlineElapsed` — this transport gave up on a body that had stopped being
    ///   worth waiting for. Distinct from `.failed` on purpose: it is the difference
    ///   between the peer failing and this side deciding.
    private final class ErrorBodyRead: @unchecked Sendable {
        enum State {
            case reading
            case ended
            case capped
            case failed(any Error)
            case deadlineElapsed
        }

        struct Snapshot {
            let body: Data
            let state: State
        }

        private let lock = NSLock()
        private let limit: Int

        // `body` and `state` are only ever read or written under `lock`.
        private var body = Data()
        private var state: State = .reading

        init(limit: Int) {
            precondition(limit >= 0)
            self.limit = limit
            body.reserveCapacity(limit)
        }

        /// Appends a byte, and reports whether the read should go on to the next one.
        ///
        /// The cap is committed here, in the same critical section as the byte that
        /// reached it. Returning `true` for that byte and committing `.capped` after the
        /// call returned would put a window between the two in which the deadline could
        /// win a transition this reader had already earned — the exact race this type
        /// exists to remove.
        func append(_ byte: UInt8) -> Bool {
            lock.withLock {
                guard case .reading = state else {
                    // Something else already decided this read is over. The byte is not
                    // wanted, and neither is any byte after it.
                    return false
                }

                guard body.count < limit else {
                    state = .capped
                    return false
                }

                body.append(byte)

                if body.count == limit {
                    // The byte above is kept — a full cap's worth of diagnostic text is
                    // the point of having a cap rather than a limit of zero.
                    state = .capped
                    return false
                }

                return true
            }
        }

        /// The server finished the body. Natural EOF, and nothing else.
        @discardableResult
        func end() -> Bool {
            transition(to: .ended)
        }

        /// The read failed. Superseded silently if a terminal state was already
        /// committed — which is what happens when the deadline ends the transfer and the
        /// reader reports the resulting cancellation.
        @discardableResult
        func fail(_ error: any Error) -> Bool {
            transition(to: .failed(error))
        }

        /// This transport gave up on the body.
        ///
        /// - Returns: whether the caller won the transition. `false` means the read had
        ///   already come to rest on its own, so there is nothing to give up on and — the
        ///   part that matters — no authority to end the transfer, which by then may be
        ///   one that finished cleanly.
        @discardableResult
        func markDeadlineElapsed() -> Bool {
            transition(to: .deadlineElapsed)
        }

        /// The body and the state it came to rest in, read as one value.
        ///
        /// Asked for only after the read and the deadline have both finished with this
        /// object, so `.reading` here means a caller reached for the answer before
        /// anything had produced one. That is a programming error rather than a race to
        /// be papered over: a plausible-looking fallback would let the branch throw a
        /// confident verdict about a read that never ended.
        func snapshot() -> Snapshot {
            lock.withLock {
                if case .reading = state {
                    preconditionFailure("error-body read was inspected before reaching a terminal state")
                }

                return Snapshot(body: body, state: state)
            }
        }

        /// The one transition out of `.reading`, and the only way any state is written
        /// after construction.
        private func transition(to terminal: State) -> Bool {
            lock.withLock {
                guard case .reading = state else {
                    return false
                }

                state = terminal
                return true
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
