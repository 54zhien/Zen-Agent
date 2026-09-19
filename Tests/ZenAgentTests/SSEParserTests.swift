import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **an event is reassembled from the bytes it actually arrived in.**
///
/// Everything here runs against a pure value with no clock and no network, so the
/// boundaries that matter — a character split across two chunks, an event split across
/// five, a terminator that never comes — are reachable by feeding bytes rather than by
/// provoking a real connection into failing at the right moment.
///
/// The chunking test is the load-bearing one. It replays the same stream at every
/// possible split point and asserts the output never changes, because "works when the
/// network cooperates" is not the property being claimed.
@Suite("SSE parser")
struct SSEParserTests {

    // MARK: - Helpers

    private func elements(from text: String, chunkSize: Int? = nil) throws -> [SSEStreamElement] {
        var parser = SSEParser()
        let bytes = Array(text.utf8)
        guard let chunkSize else {
            return try parser.consume(bytes)
        }
        var produced: [SSEStreamElement] = []
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let end = min(start + chunkSize, bytes.count)
            produced += try parser.consume(bytes[start..<end])
        }
        return produced
    }

    private func event(_ data: String, name: String? = nil) -> SSEStreamElement {
        .event(SSEEvent(name: name, data: data))
    }

    // MARK: - The framing

    @Test("a blank line dispatches the event that preceded it")
    func blankLineDispatches() throws {
        let produced = try elements(from: "data: hello\n\n")
        #expect(produced == [event("hello")])
    }

    @Test("the separator's space is stripped, but the value's own spaces are not")
    func leadingSpaceHandling() throws {
        #expect(try elements(from: "data:hello\n\n") == [event("hello")])
        #expect(try elements(from: "data: hello\n\n") == [event("hello")])
        // The second and third spaces belong to the value.
        #expect(try elements(from: "data:   hello\n\n") == [event("  hello")])
    }

    @Test("multiple data lines join with a newline, in order")
    func multiLineDataJoins() throws {
        // The notes name this case directly: one event's `data:` lines are concatenated
        // in order, not consumed as separate events (`Provider 与模型.md:60`).
        let produced = try elements(from: "data: one\ndata: two\ndata: three\n\n")
        #expect(produced == [event("one\ntwo\nthree")])
    }

    @Test("a data line with no content is an event with an empty payload")
    func emptyDataDispatches() throws {
        #expect(try elements(from: "data:\n\n") == [event("")])
        // And a bare field name means the same thing, per the grammar.
        #expect(try elements(from: "data\n\n") == [event("")])
    }

    @Test("a blank line with nothing behind it dispatches nothing")
    func bareBlankLineIsSilent() throws {
        #expect(try elements(from: "\n\n\n") == [])
    }

    @Test("an event field names the event, and its absence stays absent")
    func eventNameIsCarried() throws {
        #expect(try elements(from: "event: chunk\ndata: x\n\n") == [event("x", name: "chunk")])
        // DeepSeek is data-only, so nil must not be turned into a default name.
        #expect(try elements(from: "data: x\n\n") == [event("x", name: nil)])
    }

    @Test("unknown fields are consumed and ignored")
    func unknownFieldsIgnored() throws {
        // `id` and `retry` are legal SSE fields this parser deliberately does not model
        // — resume semantics have to be verified per provider, not assumed
        // (`Provider 与模型.md:64`). Ignoring them must not disturb the event.
        let produced = try elements(from: "id: 42\nretry: 1000\nunknown: whatever\ndata: x\n\n")
        #expect(produced == [event("x")])
    }

    // MARK: - Line endings

    @Test("LF, CRLF and a lone CR all terminate a line")
    func lineEndings() throws {
        #expect(try elements(from: "data: x\n\n") == [event("x")])
        #expect(try elements(from: "data: x\r\n\r\n") == [event("x")])
        #expect(try elements(from: "data: x\r\r") == [event("x")])
    }

    @Test("a CRLF is one terminator, not a terminator and a blank line")
    func crlfIsNotTwoTerminators() throws {
        // Reading CR then LF as two line endings would make every event followed by a
        // spurious blank one — harmless here, and wrong.
        let produced = try elements(from: "data: a\r\ndata: b\r\n\r\n")
        #expect(produced == [event("a\nb")], "the two data lines belong to one event")
    }

    // MARK: - Comments and heartbeats

    @Test("comments are consumed and produce nothing")
    func commentsProduceNothing() throws {
        #expect(try elements(from: ": keep-alive\n\n") == [])
        #expect(try elements(from: ":\n\n") == [], "an empty comment is still a comment")
        #expect(try elements(from: ":keep-alive\n\n") == [], "no space is required after the colon")
    }

    @Test("a heartbeat between events does not disturb them")
    func heartbeatBetweenEvents() throws {
        // Written with explicit escapes rather than as a multi-line literal: Swift
        // strips the newline before the closing delimiter, which silently removed the
        // blank line that dispatches the second event and made this fail for a reason
        // that had nothing to do with heartbeats.
        let stream = "data: first\n\n: keep-alive\ndata: second\n\n"
        #expect(try elements(from: stream) == [event("first"), event("second")])
    }

    // MARK: - The terminator

    @Test("[DONE] is reported as a terminator, not as an event")
    func doneIsNotAnEvent() throws {
        let produced = try elements(from: "data: x\n\ndata: [DONE]\n\n")
        #expect(produced == [event("x"), .done])
        // It is not JSON, and nothing may try to parse it as such.
        #expect(!produced.contains(event("[DONE]")))
    }

    @Test("bytes after the terminator are ignored, not treated as a failure")
    func trailingBytesAfterDoneAreIgnored() throws {
        // A trailing newline after `data: [DONE]` is entirely ordinary. Failing on it
        // would turn a correct stream into a failed answer.
        #expect(try elements(from: "data: [DONE]\n\n\n") == [.done])
        #expect(try elements(from: "data: [DONE]\n\ndata: nonsense\n\n") == [.done])
    }

    @Test("an unterminated stream is a failure, not a clean end")
    func eofBeforeDoneFails() throws {
        // The whole point: a truncated answer must not be reported as a finished one
        // (`Provider 与模型.md:62`).
        #expect(throws: SSEParserError.unterminatedStream) {
            var parser = SSEParser()
            _ = try parser.consume(Array("data: partial answer\n\n".utf8))
            try parser.finish()
        }
    }

    @Test("a stream that reached the terminator finishes cleanly")
    func terminatedStreamFinishes() throws {
        var parser = SSEParser()
        _ = try parser.consume(Array("data: x\n\ndata: [DONE]\n\n".utf8))
        try parser.finish()
        #expect(parser.reachedTerminator)
    }

    @Test("an empty stream never reached its terminator")
    func emptyStreamIsUnterminated() throws {
        #expect(throws: SSEParserError.unterminatedStream) {
            // Bound to a `var`: `finish()` is mutating, so it cannot be called on the
            // temporary an expression would produce.
            var parser = SSEParser()
            try parser.finish()
        }
    }

    // MARK: - Splitting, the load-bearing property

    @Test("the same stream yields the same elements at every possible split point")
    func splittingChangesNothing() throws {
        // A stream with the awkward shapes in it: a multi-byte character, a multi-line
        // event, a heartbeat, CRLF, and the terminator.
        let stream = "data: {\"content\":\"héllo — 世界 🌍\"}\r\n\r\n: keep-alive\ndata: second\ndata: line\n\ndata: [DONE]\n\n"
        let bytes = Array(stream.utf8)
        let expected = try elements(from: stream)

        #expect(expected == [event("{\"content\":\"héllo — 世界 🌍\"}"), event("second\nline"), .done])

        for split in 1..<bytes.count {
            var parser = SSEParser()
            var produced = try parser.consume(bytes[0..<split])
            produced += try parser.consume(bytes[split...])
            try parser.finish()
            #expect(
                produced == expected,
                "splitting at byte \(split) of \(bytes.count) changed the result — a chunk boundary is not allowed to be observable"
            )
        }
    }

    @Test("a multi-byte character split across chunks decodes correctly")
    func splitCharacterDecodes() throws {
        // 🌍 is four bytes. Split it 1/3, 2/2 and 3/1.
        let stream = "data: 🌍\n\n"
        let bytes = Array(stream.utf8)
        for split in 1..<bytes.count {
            var parser = SSEParser()
            var produced = try parser.consume(bytes[0..<split])
            produced += try parser.consume(bytes[split...])
            #expect(
                produced == [event("🌍")],
                "a character split at byte \(split) came out wrong — this is the bug that only shows up in non-ASCII"
            )
        }
    }

    @Test("an event arriving one byte at a time is assembled the same way")
    func byteAtATime() throws {
        #expect(try elements(from: "data: hello\ndata: world\n\n", chunkSize: 1) == [event("hello\nworld")])
    }

    @Test("several events arriving in one chunk come back in order")
    func manyEventsOneChunk() throws {
        let produced = try elements(from: "data: a\n\ndata: b\n\ndata: c\n\n")
        #expect(produced == [event("a"), event("b"), event("c")])
    }

    @Test("a JSON payload split across chunks is reassembled before parsing")
    func splitJSONPayload() throws {
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
        for chunk in 1...7 {
            #expect(
                try elements(from: stream, chunkSize: chunk) == [event("{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}")],
                "chunk size \(chunk) changed the payload"
            )
        }
    }

    // MARK: - Malformed input

    @Test("invalid UTF-8 fails the stream rather than substituting a replacement character")
    func invalidUTF8Fails() throws {
        // 0xFF can never start a valid UTF-8 sequence.
        #expect(throws: SSEParserError.invalidUTF8) {
            var parser = SSEParser()
            _ = try parser.consume(Array("data: ".utf8) + [0xFF, 0xFE] + Array("\n\n".utf8))
        }
    }

    @Test("a NUL byte is a framing violation")
    func nulByteFails() throws {
        #expect(throws: SSEParserError.malformedFrame("a NUL byte cannot appear in an event stream")) {
            var parser = SSEParser()
            _ = try parser.consume(Array("data: a".utf8) + [0x00] + Array("b\n\n".utf8))
        }
    }

    @Test("a line longer than the bound is refused rather than buffered")
    func lineBoundIsEnforced() throws {
        // The ceiling the design notes leave out: without it, a stream that never sends
        // a newline grows the buffer until the process dies.
        #expect(throws: SSEParserError.bufferLimitExceeded(limit: 64)) {
            var parser = SSEParser(limits: SSEParserLimits(maxLineBytes: 64, maxEventBytes: 4096))
            _ = try parser.consume(Array(("data: " + String(repeating: "x", count: 128) + "\n\n").utf8))
        }
    }

    @Test("an event larger than the bound is refused")
    func eventBoundIsEnforced() throws {
        // Ten lines of 16 bytes each: each contributes 17 to the running total, so the
        // 64-byte bound is passed on the fourth line — well before the event is whole.
        var stream = ""
        for _ in 0..<10 { stream += "data: " + String(repeating: "y", count: 16) + "\n" }
        stream += "\n"
        let bytes = Array(stream.utf8)

        #expect(throws: SSEParserError.bufferLimitExceeded(limit: 64)) {
            var parser = SSEParser(limits: SSEParserLimits(maxLineBytes: 1024, maxEventBytes: 64))
            _ = try parser.consume(bytes)
        }
    }

    @Test("the default bounds do not fire on traffic of a realistic size")
    func defaultLimitsAllowRealisticTraffic() throws {
        // A bound that fired on legitimate traffic would be worse than none, so this
        // checks the defaults against something far larger than a real chunk rather
        // than against a conveniently tiny sample.
        let payload = String(repeating: "z", count: 200_000)
        #expect(try elements(from: "data: \(payload)\n\n") == [event(payload)])
    }
}
