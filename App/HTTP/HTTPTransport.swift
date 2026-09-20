import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

/// A request as the transport layer sees it.
///
/// **Self-redacting.** This type carries the `Authorization` header — it has to, that is
/// what it is for — so the danger is not that the secret is here but that it gets
/// printed. A crash report, a network log, a `print` someone left behind: all of them
/// walk a struct's fields, which is why `customMirror` is needed and not just a nicer
/// `description`.
///
/// Same technique as `SecretValue`, for the same reason, in the one other place a secret
/// is legitimately in memory.
struct HTTPRequest: Sendable {
    var method: HTTPMethod
    var url: URL
    var headers: [String: String]
    var body: Data?

    init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Header names whose values never appear in diagnostics.
    ///
    /// Compared case-insensitively: HTTP header names are, and `Authorization` and
    /// `authorization` are the same header.
    static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
    ]

    static func isSensitive(header name: String) -> Bool {
        sensitiveHeaderNames.contains(name.lowercased())
    }

    /// The headers with sensitive values replaced. Safe to log.
    var redactedHeaders: [String: String] {
        headers.mapValues { _ in "<redacted>" }
            .merging(
                headers.filter { !Self.isSensitive(header: $0.key) },
                uniquingKeysWith: { _, safe in safe }
            )
    }
}

extension HTTPRequest: CustomStringConvertible {
    var description: String {
        "\(method.rawValue) \(url.absoluteString) headers=\(redactedHeaders)"
    }
}

extension HTTPRequest: CustomDebugStringConvertible {
    var debugDescription: String { description }
}

extension HTTPRequest: CustomReflectable {
    /// Empty mirror, so reflecting into a *containing* value cannot reach the headers
    /// either. This is the one that actually matters: `String(describing:)` on a struct
    /// with an `HTTPRequest` field walks into it.
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Convenience for the fakes, which describe responses as text.
    init(status: Int, headers: [String: String] = [:], json: String) {
        self.init(status: status, headers: headers, body: Data(json.utf8))
    }
}

enum HTTPTransportError: Error, Equatable {
    /// The request never completed. The message is the underlying description, which
    /// must not contain request headers — see `URLSessionHTTPTransport`.
    ///
    /// For a streaming request this means the failure happened before the response
    /// head arrived; once the head is in hand, a failure is `streamInterrupted`.
    case networkFailure(String)
    case cancelled

    /// The server answered with a non-2xx status, before any of the body was streamed.
    ///
    /// Carries the **whole response** so the caller maps it with the same status→error
    /// mapping it already applies to `send`. A streaming request that is refused is
    /// refused in the same vocabulary as one that is not — one mapping, not two.
    ///
    /// The body is read from the response already in flight. Re-issuing the request to
    /// collect an error body would be a second POST, which is the one thing a transport
    /// for this API must never do.
    case httpStatus(HTTPResponse)

    /// A refused response's body did not finish arriving within the window allowed for
    /// it — see `StreamTimeoutPolicy.errorBodyDeadline`.
    ///
    /// **Not `inactivityTimeout`.** Both are deadlines on a body that stopped arriving,
    /// and they point in opposite directions: that one says the connection went quiet,
    /// this one says the connection is fine and the body is not worth waiting for. A
    /// report that confused them would send someone to look at keep-alives and read
    /// timeouts for a server that was answering steadily the whole time.
    ///
    /// **Not `cancelled`**, although ending the transfer is how the deadline releases a
    /// reader parked on a socket. That cancellation is the mechanism; this is the
    /// reason. Reporting the mechanism would make an expired deadline look like
    /// somebody pressing Stop.
    ///
    /// Carries the response because the status line arrives before the body does: a 401
    /// whose envelope trickled is still a 401, and dropping the status would turn a
    /// refusal into an unknown.
    case errorBodyTimeout(HTTPResponse, after: Duration)

    /// No byte arrived within the transport's liveness window.
    ///
    /// Distinct from `streamInterrupted`, and the distinction is the diagnostic: this one
    /// usually means a provider that stopped sending keep-alives or a read timeout set
    /// wrong, while a connection that dropped mid-answer is a different problem entirely
    /// (`Tool Runtime.md:322-323`). It says nothing about whether the model was producing
    /// — a keep-alive would have reset it, and a keep-alive is not model output.
    case inactivityTimeout(after: Duration)

    /// The stream stopped after the response had begun.
    ///
    /// `deliveredData` is the distinction the design notes require
    /// (`Provider 与模型.md:66`): a stream that died before delivering anything and one
    /// that died with output already delivered are different failures, and only the
    /// transport is in a position to say which happened. Whether they differ in
    /// retryability is a higher layer's judgement — this records the fact, not a verdict.
    case streamInterrupted(deliveredData: Bool, reason: String)
}

/// The seam a Provider is written against.
///
/// Deliberately small: method, URL, headers, body in; status, headers, body out. Enough
/// for a Provider transport and nothing more — no retry policy, no interceptors, no
/// middleware chain. A general networking framework built before there are three users
/// of it is a framework shaped by the first one (`开发规划.md:462-473`).
///
/// `URLSession` never appears above this protocol, which a CI check enforces.
/// A streaming response, and the handle that ends it.
///
/// **`cancel` is the point of this type.** A bare `AsyncThrowingStream` gives its
/// consumer no way to stop the transfer — it can only stop *reading*, and then hope the
/// producer notices. That hope was wired as a chain of two: cancelling the consuming task
/// was expected to end the stream, whose termination was expected to cancel the task
/// reading the socket. CI showed the chain does not hold: `URLProtocol.stopLoading` was
/// never called, so pressing Stop ended the consumer and left the request running.
///
/// So the ownership is explicit instead. `cancel` reaches the actual `URLSessionDataTask`
/// in one hop, and whoever holds this handle is responsible for calling it — no layer has
/// to infer that someone upstream has given up.
///
/// It also removes a retain cycle. The old wiring captured the reading `Task` in
/// `onTermination` while that task captured the continuation, so nothing was ever
/// released and the deallocation-driven termination could not fire either. A closure
/// holding `URLSessionDataTask` has no such loop.
struct HTTPStream: Sendable {
    var body: AsyncThrowingStream<Data, Error>
    /// Ends the transfer — the network task, not merely this end of it.
    ///
    /// Idempotent, and safe to call from any of the ways a stream ends: the consumer
    /// cancelling, a deadline expiring, a parse failing, or the protocol saying it is
    /// done. Every one of those leaves a live request behind if nobody calls it.
    let cancel: @Sendable () -> Void
}

protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Sends a request whose response body arrives incrementally.
    ///
    /// Yields the body in the chunks the network delivered. **It does not interpret
    /// them.** What the bytes mean — SSE framing, and above that a provider's JSON — is
    /// the business of the layers above; putting any of it here would make every later
    /// provider's wire format part of the transport's contract.
    ///
    /// What the transport owns is the *lifecycle*: the status and headers, delivery, the
    /// distinction between a stream that never started and one that stopped partway, and
    /// making cancellation reach the underlying request. It does not retry, and it does
    /// not decide what a failure means — see `URLSessionHTTPTransport`.
    ///
    /// A non-2xx status throws `HTTPTransportError.httpStatus` rather than returning a
    /// stream, because a refused request did not produce one.
    ///
    /// The caller **owns the returned handle** and must call `cancel` when it stops
    /// caring — including when it stops caring because the stream finished. Nothing
    /// downstream can do it on the caller's behalf.
    func stream(_ request: HTTPRequest) async throws -> HTTPStream
}
