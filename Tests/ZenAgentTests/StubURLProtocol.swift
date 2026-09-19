import Foundation

/// A `URLProtocol` that answers from a script, so the **real** `URLSessionHTTPTransport`
/// can be exercised without a network.
///
/// The alternative — testing the transport's logic through a fake standing in for it —
/// would leave the one type that actually talks to `URLSession` unverified, which is
/// where it started: nothing in this repository instantiated `URLSessionHTTPTransport`
/// at all.
///
/// Scripts are keyed by URL, and every test uses its own host, so the suites stay
/// parallel-safe without a shared "current script" the tests would have to serialise on.
/// `@unchecked Sendable` because deliveries are scheduled onto a background queue and
/// capture the instance. The mutable state they touch — the stopped flag — is behind a
/// lock; the rest is read-only after `startLoading`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Script: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Delay between chunks, so a caller can observe delivery over time.
        var chunkDelay: TimeInterval = 0
        // The failure is stored as a code rather than a `URLError`, so this type's
        // `Sendable` conformance does not rest on whether Foundation has marked
        // `URLError` as one. A code is all the script ever needs.
        /// Fails before any response is sent — a connection that died before the status
        /// line arrived, which is a different failure from one that died after it.
        var headFailureCode: URLError.Code?
        /// Fails after the chunks instead of finishing — a connection that died partway.
        var failureCode: URLError.Code?
        /// Delivers the chunks and then neither finishes nor fails — a connection that
        /// has gone quiet. The caller is left waiting, which is the state an inactivity
        /// deadline exists for.
        var stalls = false

        /// Named `delivering` rather than `chunks` so the factory does not share a name
        /// with the stored property it fills in.
        static func delivering(_ strings: [String], delay: TimeInterval = 0) -> Script {
            var script = Script()
            script.chunks = strings.map { Data($0.utf8) }
            script.chunkDelay = delay
            return script
        }
    }

    // MARK: - Registry

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var stopCounts: [String: Int] = [:]

    static func register(_ script: Script, for url: URL) {
        lock.withLock {
            scripts[key(url)] = script
            requestCounts[key(url)] = 0
            stopCounts[key(url)] = 0
        }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requestCounts[key(url)] ?? 0 }
    }

    /// How many times the underlying task was cancelled.
    ///
    /// The point of recording this is that "the caller saw a cancellation error" and
    /// "the request was actually cancelled" are different claims, and only the second
    /// one means cancellation worked.
    static func stopCount(for url: URL) -> Int {
        lock.withLock { stopCounts[key(url)] ?? 0 }
    }

    private static func key(_ url: URL) -> String { url.absoluteString }

    private static func script(for url: URL) -> Script? {
        lock.withLock { scripts[key(url)] }
    }

    private static func recordRequest(for url: URL) {
        lock.withLock { requestCounts[key(url), default: 0] += 1 }
    }

    private static func recordStop(for url: URL) {
        lock.withLock { stopCounts[key(url), default: 0] += 1 }
    }

    // MARK: - Session

    /// A session that never reaches the network.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    /// Always true, deliberately.
    ///
    /// Returning false for an unregistered URL would let the request escape to the real
    /// network — in CI, where there is none, that surfaces as an opaque timeout rather
    /// than as "this test forgot to register a script".
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopped = NSLock()
    private var isStopped = false

    override func startLoading() {
        guard let url = request.url, let script = Self.script(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.recordRequest(for: url)

        if let code = script.headFailureCode {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: script.status,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Delivered on a background queue so a scripted gap does not block the session's
        // thread, and so `stopLoading` can still arrive while a delivery is pending.
        for (index, chunk) in script.chunks.enumerated() {
            deliver(after: script.chunkDelay * Double(index)) { protocolInstance in
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: chunk)
            }
        }

        guard !script.stalls else { return }

        let tail = script.chunkDelay * Double(script.chunks.count)
        deliver(after: tail) { protocolInstance in
            if let code = script.failureCode {
                protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: URLError(code))
            } else {
                protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { isStopped = true }
        if let url = request.url { Self.recordStop(for: url) }
    }

    private func deliver(after delay: TimeInterval, _ body: @escaping @Sendable (StubURLProtocol) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
            body(self)
        }
    }
}
