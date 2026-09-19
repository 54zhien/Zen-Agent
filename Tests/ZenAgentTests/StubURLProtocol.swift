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
        deliverChunk(at: 0, of: script)
    }

    override func stopLoading() {
        stopped.withLock { isStopped = true }
        if let url = request.url { Self.recordStop(for: url) }
    }

    /// Delivers the script one step at a time, each step starting the next.
    ///
    /// **Chained, not scheduled in parallel, and synchronous when the script asks for no
    /// delay.** The first CI run showed why both matter. Scheduling every chunk at the
    /// same deadline let them run concurrently on the global queue, so `didLoad` calls
    /// interleaved and the body arrived shuffled; and a terminal failure could land
    /// before the caller had even received its response, which turned an interrupted
    /// stream into a failed request — a different outcome, and one the tests caught
    /// because they assert the outcome rather than the plumbing.
    private func deliverChunk(at index: Int, of script: Script) {
        guard !stopped.withLock({ isStopped }) else { return }

        guard index < script.chunks.count else {
            guard !script.stalls else { return }
            if let code = script.failureCode {
                client?.urlProtocol(self, didFailWithError: URLError(code))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        let chunk = script.chunks[index]
        let next: @Sendable () -> Void = { [weak self] in
            guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
            self.client?.urlProtocol(self, didLoad: chunk)
            self.deliverChunk(at: index + 1, of: script)
        }

        if script.chunkDelay > 0 {
            // Off the session's thread, so a scripted gap neither blocks the caller's
            // start-up nor keeps `stopLoading` from arriving mid-delivery.
            DispatchQueue.global().asyncAfter(deadline: .now() + script.chunkDelay, execute: next)
        } else {
            next()
        }
    }
}
