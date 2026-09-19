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
        case chunkThenDisconnect(String)
        /// Keep writing pieces until the peer goes away.
        case continuous(String, every: TimeInterval)

        var body: String {
            switch self {
            case .chunkThenStall(let body), .chunkThenDisconnect(let body): return body
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
    private let queue = DispatchQueue(label: "local-http-server")
    private let lock = NSLock()

    private var clientFD: Int32 = -1
    private var chunkWritten = false
    private var peerWentAway = false
    private var closeRequested = false

    /// The port the system assigned. Read it from here rather than assuming one.
    let port: UInt16

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Whether the scripted body piece has actually been written to the socket.
    var wroteChunk: Bool { lock.withLock { chunkWritten } }

    /// Whether the server has observed the client going away — by `read` returning zero,
    /// or by a write failing. This is the fact a cancellation test needs: not "the caller
    /// stopped reading", but "the connection ended".
    var observedPeerClose: Bool { lock.withLock { peerWentAway } }

    /// Lets a `.chunkThenDisconnect` script proceed to closing.
    func requestClose() { lock.withLock { closeRequested = true } }

    // MARK: - Lifecycle

    init(script: Script) throws {
        self.script = script

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket() failed: \(errno)") }

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
        queue.async { [self] in serveOneConnection() }
    }

    /// Deterministic teardown. Safe to call more than once, and safe from a `defer`.
    func shutdown() {
        lock.withLock {
            closeRequested = true
            if clientFD >= 0 {
                close(clientFD)
                clientFD = -1
            }
        }
        // The listening socket is closed outside the lock so a concurrently-parked
        // `accept` is released rather than left holding it.
        close(listenFD)
    }

    // MARK: - Serving

    private func serveOneConnection() {
        let accepted = accept(listenFD, nil, nil)
        guard accepted >= 0 else { return }
        lock.withLock { clientFD = accepted }

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
            let n = read(accepted, &buffer, buffer.count)
            if n <= 0 { return }
            request.append(contentsOf: buffer[0..<n])
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
            let n = read(fd, &buffer, buffer.count)
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
        let head = "HTTP/1.1 200 OK\r\n"
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
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
