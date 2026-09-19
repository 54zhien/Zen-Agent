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

        // The exact Foundation error is **recorded, not assumed**. An earlier version of
        // this investigation guessed `networkConnectionLost`, and guessing is what sent
        // it looking in the wrong layer.
        #expect(
            outcome.hasPrefix("threw ") && outcome.hasSuffix("after 14 bytes"),
            """
            expected the disconnect to surface as a failure after the 14 bytes already \
            delivered; got: \(outcome). What it actually reports is the input to the \
            transport's error mapping, so it is the outcome, not a detail.
            """
        )
        #expect(server.wroteChunk)
    }

    @Test("cancelling the transfer closes the connection at the server")
    func cancellationClosesTheConnection() async throws {
        let server = try LocalHTTPServer(script: .continuous("piece", every: 0.02))
        server.start()
        defer { server.shutdown() }

        let url = server.baseURL.appending(path: Self.chatCompletions)
        let session = session()
        let (bytes, _) = try await session.bytes(for: URLRequest(url: url))

        let observedBytes = ObservedFlag()
        let consumer = Task {
            do {
                for try await _ in bytes { observedBytes.raise() }
            } catch {
                // Cancellation, or the connection ending. Either is a stopped transfer.
            }
        }

        for _ in 0..<300 where !observedBytes.isRaised {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedBytes.isRaised, "the consumer never received a byte, so there was nothing to cancel")

        consumer.cancel()
        _ = await consumer.value

        // The server's own observation, not the client's report: a client that believes
        // it cancelled while the connection stays open is the failure being tested for.
        for _ in 0..<300 where !server.observedPeerClose {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            server.observedPeerClose,
            "the server never saw the connection end — the transfer outlived the interest in it"
        )
    }
}
