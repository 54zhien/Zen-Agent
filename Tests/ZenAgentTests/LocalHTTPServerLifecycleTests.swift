import Foundation
import Testing

@testable import ZenAgent

/// Does the test server actually stop?
///
/// This suite tests the harness and nothing else — no provider, no transport, no parser.
///
/// It exists because a run reported success while the log said *"Restarting after
/// unexpected exit, crash, or test timeout"*, and the only test summary in it was the
/// remainder: 91 tests where 181 had run. A worker left parked in a blocking `read`
/// keeps the host alive after every test has passed, and the runner eventually kills and
/// restarts it. Every assertion in the streaming suites had passed; none of them could
/// see this, because from inside a test the server looks finished the moment the test
/// returns.
///
/// So teardown is asserted directly: after `shutdown()`, the worker must be gone.
@Suite("Local HTTP server lifecycle")
struct LocalHTTPServerLifecycleTests {

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    /// An un-invalidated `URLSession` keeps its connection pool and delegate queue alive
    /// after the test that made it has finished, which keeps the **test host** alive.
    /// Every test here leaves a transfer in flight on purpose, so none of them can rely
    /// on the session going away by itself.
    private func withSession<T>(_ body: (URLSession) async throws -> T) async rethrows -> T {
        let session = session()
        defer { session.invalidateAndCancel() }
        return try await body(session)
    }

    /// Connects and takes one byte, so the worker is genuinely mid-script rather than
    /// still sitting in `accept` — the state that strands it.
    private func connectAndReadOneByte(_ server: LocalHTTPServer) async throws {
        try await withSession { session in
            let (bytes, _) = try await session.bytes(for: URLRequest(url: server.baseURL))
            var iterator = bytes.makeAsyncIterator()
            var received = 0
            while received == 0 {
                guard let byte = try await iterator.next() else { break }
                _ = byte
                received += 1
            }
            #expect(received == 1, "the client never got a byte, so the worker's state is not the one under test")
        }
    }

    @Test("a held-open connection's worker stops on teardown")
    func stalledWorkerTerminates() async throws {
        let server = try LocalHTTPServer(script: .chunkThenStall("piece"))
        server.start()
        try await connectAndReadOneByte(server)

        // The worker is now parked in `read`, waiting for a peer that is not going away.
        #expect(server.wroteChunk)
        #expect(!server.hasTerminated, "the worker should still be running at this point")

        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
        #expect(server.hasTerminated)
    }

    @Test("a script waiting for its gate stops on teardown")
    func gatedWorkerTerminates() async throws {
        let server = try LocalHTTPServer(script: .chunkThenDisconnect("partial"))
        server.start()
        try await connectAndReadOneByte(server)

        // Parked waiting for a `requestClose` that will never come.
        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
        #expect(server.hasTerminated)
    }

    @Test("a continuously streaming worker stops on teardown")
    func streamingWorkerTerminates() async throws {
        let server = try LocalHTTPServer(script: .continuous("piece", every: 0.02))
        server.start()
        try await connectAndReadOneByte(server)

        #expect(server.shutdown(), "LocalHTTPServer worker did not terminate")
        #expect(server.hasTerminated)
    }

    @Test("teardown is safe to call twice, and the second call is a no-op")
    func teardownIsIdempotent() async throws {
        let server = try LocalHTTPServer(script: .chunkThenStall("piece"))
        server.start()
        try await connectAndReadOneByte(server)

        #expect(server.shutdown())
        // `deinit` calls this again on every server, so the second call is the normal
        // path rather than an edge case.
        #expect(server.shutdown())
        #expect(server.hasTerminated)
    }
}
