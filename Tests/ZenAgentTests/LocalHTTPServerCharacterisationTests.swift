import Foundation
import Testing

@testable import ZenAgent

/// Can a real localhost connection do what the stub could not?
///
/// The scripted `URLProtocol` was characterised and found unable to express "a small
/// body delivered, and then the connection stays open" — a single `didLoad` with the
/// request left open never reached the `AsyncBytes` consumer. Every streaming
/// integration test was therefore asserting something its instrument could not produce.
///
/// These tests ask the same three questions of a real socket, and **contain no Zen
/// code**. Until they pass, a failure in the transport tests cannot be attributed.
///
/// Every test is bounded at seconds, so a harness that stops working reads as a failed
/// test rather than as a three-minute silence.
@Suite("Localhost streaming characterisation")
struct LocalHTTPServerCharacterisationTests {

    private static let watchdog: Duration = .seconds(5)
    private static let chatCompletions = "chat/completions"

    /// Whole-experiment bound, the `bytes(for:)` call included — bounding only the
    /// iteration left an earlier version running for the full sixty-second default.
    private func observed(_ body: @escaping @Sendable () async -> String) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: Self.watchdog)
                return "the harness did not finish within \(Self.watchdog)"
            }
            let first = await group.next() ?? "no outcome"
            group.cancelAll()
            return first
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    @Test("a small body is consumed while the connection is still open")
    func incrementalDelivery() async throws {
        let server = try LocalHTTPServer(script: .chunkThenStall("first-piece"))
        server.start()
        defer { server.shutdown() }

        let url = server.baseURL.appending(path: Self.chatCompletions)

        let outcome = await observed { [session = session()] in
            do {
                let (bytes, _) = try await session.bytes(for: URLRequest(url: url))
                var received = Data()
                // The whole question: does the consumer get bytes *before* the response
                // ends? The server holds the connection open, so if anything arrives at
                // all, it arrived while the transfer was under way.
                for try await byte in bytes {
                    received.append(byte)
                    if received.count >= 11 { break }
                }
                return "received \(String(decoding: received, as: UTF8.self))"
            } catch {
                return "threw: \(error)"
            }
        }

        #expect(
            outcome == "received first-piece",
            """
            expected the body to arrive while the connection stayed open; got: \(outcome). \
            The scripted URLProtocol could not do this, which is why this server exists.
            """
        )
        #expect(server.wroteChunk, "the server never wrote its piece")
    }

    @Test("a disconnect after delivery is observed, and the bytes already received survive")
    func midStreamDisconnect() async throws {
        let server = try LocalHTTPServer(script: .chunkThenDisconnect("partial-answer"))
        server.start()
        defer { server.shutdown() }

        let url = server.baseURL.appending(path: Self.chatCompletions)

        let outcome = await observed { [session = session()] in
            var received = Data()
            do {
                let (bytes, _) = try await session.bytes(for: URLRequest(url: url))
                for try await byte in bytes {
                    received.append(byte)
                    // The handshake: the connection dies because bytes were observed,
                    // not because time passed.
                    if received.count == 14 { server.requestClose() }
                }
                return "ended cleanly after \(received.count) bytes"
            } catch {
                let code = (error as? URLError)?.code.rawValue ?? -1
                return "threw \(code) after \(received.count) bytes"
            }
        }

        // **Recorded, not assumed — and the recording is the interesting part.**
        //
        // A server closing the socket mid-response surfaces to `bytes(for:)` as a
        // *clean end*, not as a thrown error: CI reported "ended cleanly after 14
        // bytes", not a `URLError`. An earlier version of this investigation assumed
        // `networkConnectionLost`, and that assumption is part of what sent it looking
        // in the wrong layer.
        //
        // What follows for the design is not a workaround but a division of labour. A
        // byte stream that can end without an error cannot be the thing that decides
        // whether an answer was truncated — which is exactly why that judgement lives
        // in `SSEParser.finish()`, on whether the protocol's terminator ever arrived.
        // The transport's `streamInterrupted` is for failures that do throw; a clean
        // end that is missing its terminator is caught one layer up.
        //
        // So the assertion is on what must hold either way: whatever the stream reports,
        // the bytes already delivered survive and the iteration terminates.
        #expect(
            outcome.hasSuffix("after 14 bytes"),
            """
            the 14 bytes delivered before the connection died must survive, and the \
            iteration must end; got: \(outcome)
            """
        )
        #expect(server.wroteChunk)
        #expect(
            outcome == "ended cleanly after 14 bytes",
            """
            the recorded outcome changed. It was a clean end, which is what the parser's \
            terminator check exists to catch; if it is now a thrown error the transport's \
            error mapping is the layer that sees it, and that is worth knowing. Got: \(outcome)
            """
        )
    }

    @Test("cancelling the URLSession task ends a real connection")
    func taskCancellationClosesTheConnection() async throws {
        let server = try LocalHTTPServer(script: .continuous("piece", every: 0.02))
        server.start()
        defer { server.shutdown() }

        let url = server.baseURL.appending(path: Self.chatCompletions)
        let session = session()

        // Bounded as a whole, and it reports **which phase stalled** rather than just
        // that something did — an earlier version of this file was unbounded and the
        // runner restarted the process, which read as a mystery rather than as a phase.
        let outcome = await observed {
            do {
                let (bytes, _) = try await session.bytes(for: URLRequest(url: url))

                let observedBytes = ObservedFlag()
                let consumer = Task {
                    do {
                        for try await _ in bytes { observedBytes.raise() }
                    } catch {
                        // Cancellation, or the connection ending. Either is a stopped transfer.
                    }
                }
                defer { consumer.cancel() }

                for _ in 0..<100 where !observedBytes.isRaised {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard observedBytes.isRaised else { return "stalled at: byte never observed" }

                // **The transfer itself — not the Swift task standing next to it.**
                //
                // `consumer.cancel()` cancels the task iterating the sequence, and
                // nothing guarantees that reaches the URLSession task underneath. That
                // propagation is exactly what Zen's `HTTPStream` exists to stop
                // depending on, so it is not this boundary's contract either. What is
                // being characterised here is Foundation and the socket:
                // `URLSessionDataTask.cancel()` → the TCP connection ends.
                bytes.task.cancel()

                let finished = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { _ = await consumer.value; return true }
                    group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                guard finished else { return "stalled at: task cancelled but the consumer did not finish" }

                // The server's own observation, not the client's report. A client that
                // believes it cancelled while the connection stays open is the failure
                // being tested for.
                for _ in 0..<100 where !server.observedPeerClose {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard server.observedPeerClose else {
                    return "stalled at: consumer finished but the server did not observe the close"
                }

                return "ok"
            } catch {
                return "threw: \(error)"
            }
        }

        #expect(outcome == "ok", "\(outcome)")
    }
}
