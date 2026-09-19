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

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: Self.urlRequest(from: request))
        } catch {
            // The head never arrived, so this is not an interrupted stream — there was
            // no stream yet.
            throw Self.transportError(from: error)
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
                for try await byte in bytes { body.append(byte) }
            } catch {
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

        return AsyncThrowingStream { continuation in
            let task = Task {
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
                                    deliveredData: progress.hasAdvanced
                                )
                            )
                        }
                    }
                )
            }
            // Cancelling the consumer cancels the request. Without this the URLSession
            // task would outlive the thing that asked for it and keep the connection
            // open, which is exactly the failure `Agent Runtime.md:261` warns about —
            // a late result still arriving after the run it belonged to was stopped.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private static func urlRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
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
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        // The error's own description, never the request's. `URLError` carries the
        // failing URL and a code; a message built from the request would carry the
        // Authorization header, and this string ends up in logs.
        return .networkFailure(describe(error))
    }

    /// The same mapping, with the one difference a stream introduces.
    ///
    /// A failure that arrives before the head is a failed request; one that arrives
    /// after it is an interrupted stream, and the caller needs to know which bytes had
    /// already been handed over.
    private static func streamError(from error: Error, deliveredData: Bool) -> HTTPTransportError {
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
