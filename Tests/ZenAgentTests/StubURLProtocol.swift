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
        /// Delay before the terminator, when it needs a different gap from the chunks.
        ///
        /// Separate from `chunkDelay` because "the response arrived, data was delivered,
        /// and *then* the connection died" needs the first chunk delivered synchronously
        /// — so the response is established — and the failure noticeably later, so the
        /// caller has actually resumed and is reading. Sharing one delay cannot express
        /// that, and a failure that arrives too early is indistinguishable from one that
        /// arrived before the response did.
        var tailDelay: TimeInterval?
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
        /// Delivers the chunks, then waits for the test to say when the connection dies.
        ///
        /// The alternative is a delay long enough to *hope* the transport has seen the
        /// data, which is a guess about Foundation's scheduling. With a handshake the
        /// test says `triggerFailure` at the moment it has a byte in hand, so the
        /// disconnect is caused by an observation rather than by elapsed time.
        var awaitsFailureTrigger = false

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
    nonisolated(unsafe) private static var deliveryCounts: [String: Int] = [:]

    static func register(_ script: Script, for url: URL) {
        lock.withLock {
            scripts[key(url)] = script
            requestCounts[key(url)] = 0
            stopCounts[key(url)] = 0
            deliveryCounts[key(url)] = 0
        }
    }

    /// How many chunks this stub has handed to the session.
    ///
    /// Counted on the **producer** side, which is what makes "nothing was delivered
    /// after cancellation" falsifiable. A counter incremented by the consumer's own
    /// loop can only say how much the consumer took; once it stops, such a counter is
    /// incapable of moving, and the assertion that it did not move proves nothing.
    static func deliveryCount(for url: URL) -> Int {
        lock.withLock { deliveryCounts[key(url)] ?? 0 }
    }

    private static func recordDelivery(for url: URL) {
        lock.withLock { deliveryCounts[key(url), default: 0] += 1 }
    }

    nonisolated(unsafe) private static var failureTriggers: [String: @Sendable () -> Void] = [:]

    /// Kills the connection, on the test's terms rather than on a timer's.
    static func triggerFailure(for url: URL) {
        lock.withLock { failureTriggers[key(url)] }?()
    }

    private static func registerFailureTrigger(for url: URL, _ trigger: @escaping @Sendable () -> Void) {
        lock.withLock { failureTriggers[key(url)] = trigger }
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
        deliverStep(at: 0, of: script)
    }

    override func stopLoading() {
        stopped.withLock { isStopped = true }
        if let url = request.url { Self.recordStop(for: url) }
    }

    /// Delivers the script one step at a time, each step starting the next.
    ///
    /// **Chained, and the delay applies to the terminator too.** The first CI run showed
    /// why chaining matters: scheduling every chunk at the same deadline let them run
    /// concurrently, so `didLoad` calls interleaved and the body arrived shuffled.
    ///
    /// The delay on the *terminator* is the subtler half. With everything delivered in
    /// one burst, URLSession ends the task failed before the caller's byte stream ever
    /// resumes — so a response that delivered data and then died arrives as neither, and
    /// an interrupted stream is indistinguishable from a request that never got a
    /// response. That is not a limitation of the transport; it is what happens when a
    /// connection's whole life occurs inside one run-loop turn, which no real connection
    /// does. A script that wants to model "delivered, then died" has to give the bytes
    /// and the failure separate moments.
    private func deliverStep(at index: Int, of script: Script) {
        guard !stopped.withLock({ isStopped }) else { return }

        // Chunks delivered, and the disconnect is the test's to trigger. Registered here
        // and fired from the test, so the failure cannot arrive before the consumer has
        // actually observed a byte.
        if index >= script.chunks.count, script.awaitsFailureTrigger {
            guard let code = script.failureCode, let url = request.url else { return }
            Self.registerFailureTrigger(for: url) { [weak self] in
                guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            }
            return
        }

        let step: (@Sendable () -> Void)?
        if index < script.chunks.count {
            let chunk = script.chunks[index]
            step = { [weak self] in
                guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
                if let url = self.request.url { Self.recordDelivery(for: url) }
                self.client?.urlProtocol(self, didLoad: chunk)
                self.deliverStep(at: index + 1, of: script)
            }
        } else if script.stalls {
            step = nil
        } else if let code = script.failureCode {
            // The `isStopped` check every branch needs, not just the chunk branch. A
            // terminal callback delivered after `stopLoading` violates the
            // `URLProtocol` contract — and in a cancellation test it would mean one
            // request reporting both a cancellation and a spurious connection loss.
            step = { [weak self] in
                guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        } else {
            step = { [weak self] in
                guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }

        guard let step else { return }

        let delay = index < script.chunks.count ? script.chunkDelay : (script.tailDelay ?? script.chunkDelay)
        if delay > 0 {
            // Off the session's thread, so a scripted gap neither blocks the caller's
            // start-up nor keeps `stopLoading` from arriving mid-delivery.
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: step)
        } else {
            step()
        }
    }
}
