import Foundation

/// A minimal HTTP/1.1 server on localhost, for tests that need a **real** streaming
/// connection.
///
/// It exists because a scripted `URLProtocol` turned out not to be a sound oracle for
/// streaming: characterised in `URLProtocolCharacterisationTests`, a small body written
/// with the request left open never reached the `AsyncBytes` consumer. That is a fact
/// about the stub, not about `bytes(for:)` — so the behaviour those tests need is
/// produced by an actual socket instead of by a stub imitating one.
///
/// **Deliberately not a web server.** No TLS, no HTTP/2, no routing, no middleware. It
/// accepts one connection, writes what a script says, and reports what it observed. A
/// general server built for three scripts would be a framework shaped by its first
/// caller, and the point is to test something else.
///
/// Binds `127.0.0.1` on an **ephemeral port**, so instances never collide and the suite
/// stays parallel-safe. Each test owns one instance and is responsible for `shutdown`.
final class LocalHTTPServer: @unchecked Sendable {

    enum Script: Sendable {
        /// Write one body piece, flush, and hold the connection open indefinitely.
        case chunkThenStall(String)
        /// Write a partial body, flush, wait for `requestClose`, then disconnect.
        ///
        /// A **graceful** close, kept exactly as it is: its clean-EOF behaviour is
        /// measured and recorded in `LocalHTTPServerCharacterisationTests`. Do not
        /// repurpose it for a test that needs a throwing failure.
        case chunkThenDisconnect(String)
        /// Write a partial body, flush, wait for `requestClose`, then disconnect
        /// **abortively** — an RST rather than a FIN.
        ///
        /// Distinct from `chunkThenDisconnect` for a measured reason: a graceful close
        /// reaches `bytes(for:)` as a clean end, and a clean end is not a throwing
        /// failure. The graceful script produced "ended cleanly after 14 bytes".
        case chunkThenAbort(String)
        /// Keep writing pieces until the peer goes away.
        case continuous(String, every: TimeInterval)

        var body: String {
            switch self {
            case .chunkThenStall(let body), .chunkThenDisconnect(let body),
                 .chunkThenAbort(let body):
                return body
            case .continuous(let body, _): return body
            }
        }
    }

    enum Failure: Error {
        case socket(String)
        case bind(String)
        case listen(String)
    }

    private let listenFD: Int32
    private let script: Script
    /// The status line to answer with. Anything outside `200..<300` exercises the
    /// transport's **refusal** path, which reads a body it does not stream — a path
    /// where the connection has to be ended by the client, because no stream handle
    /// exists for anyone else to end it with.
    private let status: Int
    /// Test-only. Runs after `accept()` returns and **before** the descriptor is
    /// published, so a regression can drive the publication race deterministically
    /// instead of hoping for the interleaving.
    private let prePublicationHook: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "local-http-server")
    private let lock = NSLock()
    /// Records that the worker has actually finished, so teardown can prove it rather
    /// than assume it.
    private let workers = DispatchGroup()

    private var clientFD: Int32 = -1
    private var chunkWritten = false
    private var peerWentAway = false
    private var closeRequested = false
    private var closed = false
    private var terminated = false

    /// The port the system assigned. Read it from here rather than assuming one.
    let port: UInt16

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Whether the scripted body piece has actually been written to the socket.
    var wroteChunk: Bool { lock.withLock { chunkWritten } }

    /// Whether the server has observed the client going away — by `read` returning zero,
    /// or by a write failing. This is the fact a cancellation test needs: not "the caller
    /// stopped reading", but "the connection ended".
    var observedPeerClose: Bool { lock.withLock { peerWentAway } }

    /// Whether the worker has run to completion. False means it is still parked in a
    /// blocking call, which is the state that leaves a test host alive after its tests
    /// have finished.
    var hasTerminated: Bool { lock.withLock { terminated } }

    /// Whether teardown has begun. Test-only observation, for the publication race:
    /// the regression needs to see that `shutdown()` has won before it lets the worker
    /// continue.
    var isClosed: Bool { lock.withLock { closed } }

    /// Lets a `.chunkThenDisconnect` script proceed to closing.
    func requestClose() { lock.withLock { closeRequested = true } }

    // MARK: - Lifecycle

    init(
        script: Script,
        status: Int = 200,
        prePublicationHook: (@Sendable () -> Void)? = nil
    ) throws {
        self.script = script
        self.status = status
        self.prePublicationHook = prePublicationHook

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket() failed: \(errno)") }
        guard Self.suppressSIGPIPE(on: fd) else {
            close(fd)
            throw Failure.socket("SO_NOSIGPIPE could not be set: \(errno)")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure.bind("bind() failed: \(errno)")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw Failure.listen("listen() failed: \(errno)")
        }

        // Ask the system which port it gave us, rather than guessing one.
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw Failure.bind("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit {
        shutdown()
    }

    /// Starts accepting. Returns immediately; the script runs on its own queue.
    func start() {
        workers.enter()
        queue.async { [self] in
            defer {
                lock.withLock { terminated = true }
                workers.leave()
            }
            serveOneConnection()
        }
    }

    /// Deterministic teardown, which **proves the worker stopped** rather than assuming
    /// it did.
    ///
    /// Emitting a close and returning is not teardown. A worker still parked in a
    /// blocking `read` keeps the process alive after its tests have passed, and the
    /// runner eventually restarts the whole host — which is what happened here: the
    /// workflow reported success while the log said "Restarting after unexpected exit",
    /// and the only test summary in it was the remainder.
    ///
    /// ## Who owns which descriptor
    ///
    /// - **`listenFD`** belongs to the server. Shut down and closed exactly once, here.
    /// - **`clientFD`** belongs to the **worker**, which closes it. This method only
    ///   calls `shutdown(2)` on it, to release a parked `read`/`write`.
    ///
    /// That split is the point. Closing a descriptor another thread may still be using
    /// is how a number gets recycled underneath it, and the previous version both closed
    /// the client here *and* had the worker close it — two owners, one integer. Both
    /// paths now touch it under the same lock, and only one of them closes it.
    ///
    /// - Returns: whether the worker had terminated by the time the bounded wait expired.
    @discardableResult
    func shutdown() -> Bool {
        let firstShutdown: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            closeRequested = true
            if clientFD >= 0 {
                // Releases a parked read or write. Deliberately not `close`: the worker
                // owns this descriptor.
                Darwin.shutdown(clientFD, SHUT_RDWR)
            }
            return true
        }
        if firstShutdown {
            // Releases a parked `accept`. Closing alone is not a contract that an
            // in-progress accept returns promptly, so both are done.
            Darwin.shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        return workers.wait(timeout: .now() + Self.workerExitBudget) == .success
    }

    /// Bounded, because a test that hangs is a test that cannot report. Short enough to
    /// fail inside a test rather than to be cleaned up by the runner.
    private static let workerExitBudget: TimeInterval = 3

    // MARK: - Serving

    /// `read`/`write`/`accept` can be interrupted by a signal and return `-1` with
    /// `EINTR`. That is not a closed socket, and treating it as one marks the peer gone
    /// while the connection is perfectly alive — a test-server correctness matter,
    /// independent of whatever the tests are investigating.
    private func retryingOnInterrupt<T: FixedWidthInteger>(_ call: () -> T) -> T {
        while true {
            let result = call()
            if result < 0 && errno == EINTR { continue }
            return result
        }
    }

    /// Stops a write to a closed peer from killing the process.
    ///
    /// A `write` to a socket whose peer has gone raises `SIGPIPE`, and the **default
    /// disposition of that signal is to terminate the process**. The test host died of
    /// exactly this: the simulator's Unified Log records
    /// `com.zhien.zenagent.ZenAgent[6766] exited due to SIGPIPE`, and RunningBoard
    /// reports `domain:signal(2) code:SIGPIPE(13)`.
    ///
    /// `SO_NOSIGPIPE` is set per-socket rather than ignoring the signal process-wide.
    /// `signal(SIGPIPE, SIG_IGN)` would change behaviour for the whole test host and
    /// could mask the same bug anywhere else; this keeps the change to the descriptors
    /// this server owns. With it set, a write to a departed peer returns `EPIPE`
    /// instead, which `sendAll` already treats as the peer being gone.
    ///
    /// - Returns: whether the option was applied. A socket without it must not be used.
    private static func suppressSIGPIPE(on fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0
    }

    /// Makes the next `close` on this descriptor abortive.
    ///
    /// `SO_LINGER` with a zero interval makes `close` discard the send buffer and send
    /// RST, which the client observes as a failed transfer rather than a tidy end of
    /// body. That distinction is the whole reason this exists: the graceful close used
    /// by `chunkThenDisconnect` arrives at `bytes(for:)` as a **clean end**, which is
    /// not a throwing failure and so cannot produce the condition the transport's
    /// `streamInterrupted` describes.
    ///
    /// Best-effort by design. If the option cannot be set the close is merely graceful,
    /// which is a weaker test rather than a broken server - and the characterisation
    /// that depends on the abort is what decides whether that happened.
    private static func enableAbortiveClose(on fd: Int32) {
        var option = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
    }

    /// `< 0` after a retry is a genuine error, which for a socket we are reading or
    /// writing means the same thing as EOF: the peer is gone.
    private func readSome(_ fd: Int32, _ buffer: inout [UInt8]) -> Int {
        retryingOnInterrupt { read(fd, &buffer, buffer.count) }
    }

    private func serveOneConnection() {
        let accepted = retryingOnInterrupt { accept(listenFD, nil, nil) }
        guard accepted >= 0 else { return }
        // Set on the accepted socket too, not only the listening one. This is the
        // descriptor the server actually writes to, so the behaviour must not depend on
        // an option propagating from the listener - and whether it does is not something
        // this repository has verified. Setting it here makes the question moot.
        guard Self.suppressSIGPIPE(on: accepted) else {
            close(accepted)
            return
        }

        prePublicationHook?()

        // Publication and the closed check are **one transition under one lock**.
        //
        // They used to be separate, which left a window: `shutdown()` could run between
        // `accept()` returning and `clientFD` being published, see -1, and conclude
        // there was nothing to release - while the worker went on to publish the
        // descriptor and park in a blocking `read()`. Shutdown then returned having
        // released nothing, and the worker kept the process alive until the runner
        // reaped it.
        //
        // Taking the same lock for both means shutdown either sees a published
        // descriptor and releases it, or wins the race and the worker gives the
        // descriptor up instead of using it.
        let published: Bool = lock.withLock {
            guard !closed else { return false }
            clientFD = accepted
            return true
        }
        guard published else {
            // Shutdown won, so this descriptor was never published and nothing else
            // will close it. The worker must not use it either.
            close(accepted)
            return
        }

        defer {
            lock.withLock {
                if clientFD >= 0 { close(clientFD); clientFD = -1 }
            }
        }

        // Read the request head. A test client sends a small one; anything longer than
        // this is not something these scripts need to answer.
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 8192 {
            let n = readSome(accepted, &buffer)
            if n <= 0 { return }
            request.append(contentsOf: buffer[0..<Int(n)])
        }

        guard writeHead(to: accepted) else { markPeerGone(); return }

        switch script {
        case .chunkThenStall(let body):
            _ = writeChunk(body, to: accepted)
            // Then hold the socket open and watch for the peer leaving.
            awaitPeerDeparture(accepted)

        case .chunkThenDisconnect(let body):
            _ = writeChunk(body, to: accepted)
            // Wait for the test, never for a duration.
            while !closeRequestedNow() { Thread.sleep(forTimeInterval: 0.005) }
            // Closing here is what the client observes as the connection dying.

        case .chunkThenAbort(let body):
            _ = writeChunk(body, to: accepted)
            while !closeRequestedNow() { Thread.sleep(forTimeInterval: 0.005) }
            // Arm the close the `defer` is about to perform, so it aborts rather than
            // says goodbye politely.
            Self.enableAbortiveClose(on: accepted)

        case .continuous(let body, let every):
            while !closeRequestedNow() {
                guard writeChunk(body, to: accepted) else { markPeerGone(); return }
                Thread.sleep(forTimeInterval: every)
            }
        }
    }

    private func closeRequestedNow() -> Bool { lock.withLock { closeRequested } }

    /// Blocks reading until the client goes away, which is what a held-open connection
    /// eventually does when the caller cancels.
    private func awaitPeerDeparture(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            if closeRequestedNow() { return }
            let n = readSome(fd, &buffer)
            if n <= 0 {
                // Zero is EOF: the peer closed. Anything negative is an error, which for
                // a connection we are deliberately not writing to means the same thing.
                markPeerGone()
                return
            }
        }
    }

    private func markPeerGone() { lock.withLock { peerWentAway = true } }

    // MARK: - Writing

    private func writeHead(to fd: Int32) -> Bool {
        // Chunked, because the whole point is a body that arrives in pieces while the
        // response is still open. `Content-Length` would promise an end that these
        // scripts deliberately do not send.
        //
        // The reason phrase comes from the system's own table rather than one invented
        // here. Nothing reads it — HTTP/1.1 makes it advisory and the code is the
        // contract — which is why no script or assertion depends on the text.
        let head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
        return sendAll(fd, Data(head.utf8))
    }

    private func writeChunk(_ body: String, to fd: Int32) -> Bool {
        let payload = Data(body.utf8)
        let header = Data("\(String(payload.count, radix: 16))\r\n".utf8)
        let ok = sendAll(fd, header) && sendAll(fd, payload) && sendAll(fd, Data("\r\n".utf8))
        if ok { lock.withLock { chunkWritten = true } } else { markPeerGone() }
        return ok
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let written = retryingOnInterrupt { write(fd, base + offset, raw.count - offset) }
                if written <= 0 { return false }
                offset += Int(written)
            }
            return true
        }
    }
}
