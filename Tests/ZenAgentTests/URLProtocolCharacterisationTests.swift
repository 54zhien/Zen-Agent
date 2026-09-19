import Foundation
import Testing

@testable import ZenAgent

/// What can this harness actually express?
///
/// This suite exists because two tests hung or failed for reasons that could not be told
/// apart from the behaviour they were investigating. A harness that cannot be shown to
/// reproduce a condition is not evidence about anything else, so it is characterised on
/// its own first.
///
/// **It contains no Zen code.** Not `HTTPTransport`, not the parser, not the error
/// vocabulary, not a deadline.
///
/// ## What it establishes
///
/// In the current macOS/Xcode/Foundation environment, driving
/// `URLSession.bytes(for:)` through a custom `URLProtocol`: **a small number of
/// `didLoad` calls followed by keeping the request open does not reliably reach the
/// `AsyncBytes` consumer.** More data was delivered. A single synchronous `didLoad` with
/// the task left open did not reach the consumer at all — `bytes(for:)` itself threw
/// `-1001` after sixty seconds.
///
/// **This is a result about this test harness, and it is not extended to real HTTPS.**
/// `bytes(for:)` exists precisely to process bytes while a transfer is under way, and
/// nothing here says otherwise about a real transport. No threshold is inferred either
/// — how much is "enough" was not measured and is not claimed.
///
/// ## What follows
///
/// `StubURLProtocol` remains a sound oracle for what it has been shown to do: request
/// construction, status and error bodies, ordinary finite bodies, and explicit
/// `HTTPStream.cancel()` reaching `URLSessionDataTask.cancel`. It is **not** a sound
/// oracle for one-chunk-then-stall, cancelling an active incremental stream, or
/// mid-stream connection loss. Those need a real local HTTP server in the test target.
@Suite("URLProtocol characterisation")
struct URLProtocolCharacterisationTests {

    /// Bounds the **whole experiment**, including the `bytes(for:)` call itself.
    ///
    /// An earlier version wrapped only the byte iteration, and the suite still took
    /// sixty seconds — because `bytes(for:)` blocks before the iteration ever starts.
    /// A watchdog that does not cover the thing that hangs is not a watchdog.
    ///
    /// This guards the *test infrastructure*. It is not a product deadline, and it is
    /// set far below any of them so that a harness failure reads as a failed test.
    private static let watchdog: Duration = .seconds(3)

    private func makeURL() -> URL {
        URL(string: "https://characterise-\(UUID().uuidString).invalid")!
    }

    /// Runs `body` — the entire experiment — and gives up on it if it has not finished.
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

    @Test("a finite body is delivered through bytes(for:)")
    func finiteBodyIsDelivered() async throws {
        let url = makeURL()
        StubURLProtocol.register(.delivering(["hello"]), for: url)

        // Everything inside, `bytes(for:)` included.
        let outcome = await observed {
            do {
                let (bytes, response) = try await StubURLProtocol.makeSession().bytes(for: URLRequest(url: url))
                var received = Data()
                for try await byte in bytes { received.append(byte) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return "\(status) \(String(decoding: received, as: UTF8.self))"
            } catch {
                return "threw: \(error)"
            }
        }

        // What the rest of the suite relies on: request construction, status, and a
        // finite body. Nothing about streaming while the request stays open.
        #expect(outcome == "200 hello", "got: \(outcome)")
    }

    @Test("a chunk delivered over time is delivered through bytes(for:)")
    func chunkedBodyIsDelivered() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        // Delivered off the session's thread. This is the shape the harness *can* do —
        // enough deliveries, and a body that ends.
        script.chunks = Array(repeating: Data("x".utf8), count: 64)
        script.chunkDelay = 0.005
        StubURLProtocol.register(script, for: url)

        let outcome = await observed {
            do {
                let (bytes, _) = try await StubURLProtocol.makeSession().bytes(for: URLRequest(url: url))
                var received = 0
                for try await _ in bytes { received += 1 }
                return "received \(received)"
            } catch {
                return "threw: \(error)"
            }
        }

        #expect(outcome == "received 64", "got: \(outcome)")
    }

    // MARK: - The gate

    @Test("a failure requested before the handler exists is not lost")
    func requestBeforeHandler() async {
        // The ordering that made an earlier version hang: the request arrives first.
        // Nothing in the gate may treat that as "nothing to do".
        let gate = FailureGate()
        let fired = ObservedFlag()

        gate.requestFailure()
        gate.install { fired.raise() }

        for _ in 0..<100 where !fired.isRaised {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(fired.isRaised, "the request was dropped because it arrived before the handler")
    }

    @Test("a failure requested after the handler exists fires immediately")
    func handlerBeforeRequest() async {
        let gate = FailureGate()
        let fired = ObservedFlag()

        gate.install { fired.raise() }
        gate.requestFailure()

        for _ in 0..<100 where !fired.isRaised {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(fired.isRaised)
    }
}
