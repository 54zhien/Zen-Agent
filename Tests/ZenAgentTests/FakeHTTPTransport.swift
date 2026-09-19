import Foundation

@testable import ZenAgent

/// A transport that answers from a script, deterministically.
///
/// It implements `HTTPTransport` — the same protocol the real one does — so a test that
/// passes against it is testing the Provider's behaviour rather than a stand-in for it.
/// What it makes possible that the real transport cannot: driving every status code,
/// every malformed body and every network failure without a network, and asserting on
/// the exact bytes that would have gone out.
///
/// It records the requests it was given, including the `Authorization` header, because
/// that the header is *correct* is something worth asserting. The header being
/// *printable* is not — see `HTTPRequest.redactedHeaders`.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [HTTPResponse] = []
    private var failure: HTTPTransportError?
    private var sent: [HTTPRequest] = []
    private var sentCount = 0

    /// Body chunks a `stream` call delivers, in order.
    private var streamChunks: [Data] = []
    /// Thrown instead of returning a stream at all — the shape of a refused request.
    private var streamHeadFailure: HTTPTransportError?
    /// Thrown after the chunks — the shape of a connection that died partway.
    private var streamTailFailure: HTTPTransportError?

    init() {}

    /// Queues a response. Responses are returned in order; the last one repeats.
    func enqueue(_ response: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        scripted.append(response)
    }

    func enqueue(status: Int, json: String) {
        enqueue(HTTPResponse(status: status, json: json))
    }

    /// Makes every send fail instead of answering.
    func fail(with error: HTTPTransportError) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    // MARK: - Streaming

    /// Queues the chunks a `stream` call delivers, which then finishes normally.
    func enqueueStream(_ chunks: [String]) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks.map { Data($0.utf8) }
        streamTailFailure = nil
        streamHeadFailure = nil
    }

    /// Queues chunks as raw bytes, for the cases where the bytes are the point — a
    /// stream that is not valid UTF-8 cannot be expressed as a `String` at all.
    func enqueueStream(bytes chunks: [Data]) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks
        streamTailFailure = nil
        streamHeadFailure = nil
    }

    /// Queues chunks and then a failure — a connection that died after delivering.
    func enqueueStream(_ chunks: [String], thenFailWith error: HTTPTransportError) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks.map { Data($0.utf8) }
        streamTailFailure = error
        streamHeadFailure = nil
    }

    /// Makes `stream` throw before returning one, the way a refused request does.
    func failStream(with error: HTTPTransportError) {
        lock.lock(); defer { lock.unlock() }
        streamHeadFailure = error
        streamChunks = []
        streamTailFailure = nil
    }

    // MARK: - Inspection

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sentCount
    }

    var lastRequest: HTTPRequest? {
        lock.lock(); defer { lock.unlock() }
        return sent.last
    }

    // MARK: - HTTPTransport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // `withLock`, not `lock()`/`unlock()`: Swift refuses the latter from an async
        // context, and rightly — a suspension point between the two would leave the lock
        // held across it. Scoped locking cannot make that mistake.
        let (failure, response) = lock.withLock { () -> (HTTPTransportError?, HTTPResponse?) in
            sent.append(request)
            sentCount += 1
            let next: HTTPResponse?
            if scripted.count > 1 {
                next = scripted.removeFirst()
            } else {
                next = scripted.first
            }
            return (self.failure, next)
        }

        // Counted before any throw, so a test can assert that a failure path made
        // exactly one attempt — which is how "no hidden retry" is checked.
        if let failure { throw failure }
        guard let response else {
            throw HTTPTransportError.networkFailure("the fake had no response scripted")
        }
        return response
    }

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let script = lock.withLock { () -> (HTTPTransportError?, [Data], HTTPTransportError?) in
            // Counted like `send`, so a test can assert that a failed stream made
            // exactly one attempt. That is how "no hidden retry" is checked on this path
            // too — and it matters more here, because a replayed stream would generate
            // the answer a second time while the UI still showed one.
            sent.append(request)
            sentCount += 1
            return (streamHeadFailure, streamChunks, streamTailFailure)
        }

        if let head = script.0 { throw head }
        return AsyncThrowingStream { continuation in
            for chunk in script.1 { continuation.yield(chunk) }
            if let tail = script.2 {
                continuation.finish(throwing: tail)
            } else {
                continuation.finish()
            }
        }
    }
}
