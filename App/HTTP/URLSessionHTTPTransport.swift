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
    /// Only `transportInactivity` is used here — the other deadlines ask a question
    /// about the model, which a transport cannot answer. One policy value is passed to
    /// both layers rather than each holding its own copy of half of it.
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
            // Drain the body from the response already in flight. Issuing a second
            // request to collect an error body would be a second POST, and the whole
            // point of this transport is that it makes exactly one.
            var body = Data()
            do {
                for try await byte in bytes {
                    // Bounded, like the parser's reassembly buffers. An error body is a
                    // small JSON envelope; a server that sends megabytes, or never ends,
                    // must not be able to grow this without limit.
                    guard body.count < Self.maximumErrorBodyBytes else { break }
                    body.append(byte)
                }
            } catch {
                // Cancellation is not a refusal. Swallowing it here would report a
                // streamed 401 to someone who pressed Stop as "your credential was
                // rejected" — the exact inversion of what cancellation reporting is for.
                if Self.isCancellation(error) { throw HTTPTransportError.cancelled }
                // The status line arrived before the failure, so the status is known
                // even when the body is not. Reporting it with a partial body is more
                // useful than reporting a network failure: a 401 is a 401, and the
                // absence of readable diagnostic text is already a case the error
                // mapping handles.
            }
            throw HTTPTransportError.httpStatus(
                HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: body)
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
                        continuation.finish(throwing: HTTPTransportError.inactivityTimeout(after: elapsed))
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

    // MARK: - Request building

    /// The most of an error body worth keeping. Far above any real envelope.
    private static let maximumErrorBodyBytes = 64 << 10

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
