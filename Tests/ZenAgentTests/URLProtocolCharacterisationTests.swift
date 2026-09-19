import Foundation
import Testing

@testable import ZenAgent

/// Does the harness do what the other tests assume it does?
///
/// This suite exists because two tests hung or failed for reasons that could not be told
/// apart from the behaviour they were investigating. A harness that cannot be shown to
/// reproduce a condition is not evidence about anything else, so it is characterised on
/// its own first.
///
/// **It deliberately contains no Zen code.** Not `HTTPTransport`, not the parser, not
/// the error vocabulary, not a deadline. It answers exactly one question:
///
///     can this stub express "data was delivered, and then the connection failed"?
///
/// If it cannot, that is a finding about `URLSession.bytes(for:)` driven by a custom
/// `URLProtocol`, and it belongs in the report rather than being worked around in the
/// tests that depend on it.
@Suite("URLProtocol characterisation")
struct URLProtocolCharacterisationTests {

    /// Bounded at seconds, not at CI's three-minute default.
    ///
    /// This is a guard against the *harness* hanging, not a product deadline, and it is
    /// deliberately far below any real timeout so that a failure to deliver shows up as
    /// a failed test rather than as a long silence.
    private static let watchdog: Duration = .seconds(3)

    private func makeURL() -> URL {
        URL(string: "https://characterise-\(UUID().uuidString).invalid")!
    }

    /// Runs `body`, and gives up on it if it has not finished inside the watchdog.
    ///
    /// Returns a description rather than throwing, so the assertion can say what
    /// happened instead of just that something did not.
    private func observed(_ body: @escaping @Sendable () async -> String) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: Self.watchdog)
                return "the harness never completed within \(Self.watchdog)"
            }
            let first = await group.next() ?? "no outcome"
            group.cancelAll()
            return first
        }
    }

    @Test("bytes(for:) delivers a body that the stub wrote")
    func bytesAreDelivered() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        script.chunks = [Data("hello".utf8)]
        StubURLProtocol.register(script, for: url)

        let session = StubURLProtocol.makeSession()
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))

        let outcome = await observed {
            var received = Data()
            do {
                for try await byte in bytes { received.append(byte) }
                return "delivered \(String(decoding: received, as: UTF8.self))"
            } catch {
                return "threw before delivering \(received.count) bytes: \(error)"
            }
        }

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(outcome == "delivered hello", "got: \(outcome)")
    }

    @Test("the stub can express: a byte delivered, and then the connection lost")
    func deliveredThenFailed() async throws {
        let url = makeURL()
        var script = StubURLProtocol.Script()
        script.chunks = [Data("partial".utf8)]
        // Delivered off the session's thread. `bytes(for:)` does not hand back a
        // response body delivered inline while the task stays open — established
        // earlier, and the one Foundation behaviour this harness depends on.
        script.chunkDelay = 0.02
        script.failureCode = .networkConnectionLost
        script.failsOnRequest = true
        StubURLProtocol.register(script, for: url)

        let session = StubURLProtocol.makeSession()
        let (bytes, _) = try await session.bytes(for: URLRequest(url: url))

        let outcome = await observed {
            var received = Data()
            do {
                for try await byte in bytes {
                    let wasFirst = received.isEmpty
                    received.append(byte)
                    // The handshake. The connection dies because a byte was observed,
                    // not because time passed.
                    if wasFirst { StubURLProtocol.requestFailure(for: url) }
                }
                return "ended cleanly after \(received.count) bytes"
            } catch {
                let code = (error as? URLError)?.code.rawValue ?? -1
                return "threw \(code) after \(received.count) bytes"
            }
        }

        #expect(
            outcome == "threw -1005 after 7 bytes",
            """
            expected the harness to deliver 7 bytes and then report a lost connection \
            (-1005); got: \(outcome)
            """
        )
    }

    @Test("a failure requested before the handler exists is not lost")
    func requestBeforeHandler() async {
        // The ordering that made the earlier version hang: the request arrives first.
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
