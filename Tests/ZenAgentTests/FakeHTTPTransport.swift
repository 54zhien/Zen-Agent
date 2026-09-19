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
    /// Leaves the stream open after its chunks. See `stallStream`.
    private var streamStalls = false
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
        streamStalls = false
    }

    /// Queues chunks as raw bytes, for the cases where the bytes are the point — a
    /// stream that is not valid UTF-8 cannot be expressed as a `String` at all.
    func enqueueStream(bytes chunks: [Data]) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks
        streamTailFailure = nil
        streamHeadFailure = nil
        streamStalls = false
    }

    /// Queues chunks and then a failure — a connection that died after delivering.
    func enqueueStream(_ chunks: [String], thenFailWith error: HTTPTransportError) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks.map { Data($0.utf8) }
        streamTailFailure = error
        streamHeadFailure = nil
    }

    /// Queues chunks and then leaves the stream open — a connection that has gone quiet
    /// with the request still running. What an expiry deadline exists for.
    func stallStream(after chunks: [String]) {
        lock.lock(); defer { lock.unlock() }
        streamChunks = chunks.map { Data($0.utf8) }
        streamTailFailure = nil
        streamHeadFailure = nil
        streamStalls = false
        streamStalls = true
    }

    /// Makes `stream` throw before returning one, the way a refused request does.
    func failStream(with error: HTTPTransportError) {
        lock.lock(); defer { lock.unlock() }
        streamHeadFailure = error
        streamChunks = []
        streamTailFailure = nil
        streamStalls = false
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

    /// How many times a streaming call's handle was cancelled.
    private var streamCancelCount = 0
    /// Retained only while a scripted stall is open. A continuation that is released
    /// without being finished finishes the stream, which would defeat the stall.
    private var stalledContinuations: [AsyncThrowingStream<Data, Error>.Continuation] = []

    var streamCancellations: Int {
        lock.lock(); defer { lock.unlock() }
        return streamCancelCount
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let script = lock.withLock { () -> (HTTPTransportError?, [Data], HTTPTransportError?, Bool) in
            // Counted like `send`, so a test can assert that a failed stream made
            // exactly one attempt. That is how "no hidden retry" is checked on this path
            // too — and it matters more here, because a replayed stream would generate
            // the answer a second time while the UI still showed one.
            sent.append(request)
            sentCount += 1
            return (streamHeadFailure, streamChunks, streamTailFailure, streamStalls)
        }

        if let head = script.0 { throw head }
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                for chunk in script.1 { continuation.yield(chunk) }
                if let tail = script.2 {
                    continuation.finish(throwing: tail)
                } else if script.3 {
                    // Held open. The caller is left waiting, which is the state an
                    // expiry deadline exists to end.
                    lock.withLock { stalledContinuations.append(continuation) }
                } else {
                    continuation.finish()
                }
            },
            // Recorded rather than ignored. Whether the layer above ends the transfer it
            // was given is a claim worth being able to fail on — and a stalled stream is
            // also released here, so a caller that never cancels hangs, which is the
            // honest consequence of not ending a request.
            cancel: { [weak self] in
                guard let self else { return }
                let pending: [AsyncThrowingStream<Data, Error>.Continuation] = self.lock.withLock {
                    self.streamCancelCount += 1
                    let held = self.stalledContinuations
                    self.stalledContinuations = []
                    return held
                }
                for continuation in pending { continuation.finish() }
            }
        )
    }
}
