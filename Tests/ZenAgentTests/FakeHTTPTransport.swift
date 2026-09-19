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
        lock.lock()
        sent.append(request)
        sentCount += 1
        let failure = self.failure
        let response = scripted.isEmpty ? nil : (scripted.count == 1 ? scripted[0] : scripted.removeFirst())
        lock.unlock()

        // Counted before any throw, so a test can assert that a failure path made
        // exactly one attempt — which is how "no hidden retry" is checked.
        if let failure { throw failure }
        guard let response else {
            throw HTTPTransportError.networkFailure("the fake had no response scripted")
        }
        return response
    }
}
