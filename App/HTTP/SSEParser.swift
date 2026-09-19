import Foundation

/// One dispatched event: the `event:` name, if the stream gave one, and the assembled
/// `data:` payload.
///
/// DeepSeek's Chat Completions stream is data-only SSE — it never sends an `event:`
/// field — so `name` is optional and nothing may require it.
struct SSEEvent: Sendable, Equatable {
    var name: String?
    var data: String
}

/// What a stream yields: events, and the terminator.
///
/// `[DONE]` is not part of the SSE specification. It is OpenAI's convention, inherited by
/// DeepSeek, and it is modelled here rather than in the adapter because the alternative
/// is every adapter re-deriving end-of-stream from a string, and because "did the stream
/// reach its terminator" is the one question that decides whether a truncated answer is
/// reported as truncated. It is a *sentinel*, not a DTO — the parser still knows nothing
/// about DeepSeek's JSON.
enum SSEStreamElement: Sendable, Equatable {
    case event(SSEEvent)
    case done
}

/// Bounds on the reassembly buffers.
///
/// The design notes require that a split event be buffered until it is whole, and set no
/// ceiling on that buffer (`Provider 与模型.md:61`). A stream that never sends a newline,
/// whether through corruption or on purpose, would then grow without limit — so this is
/// the ceiling the notes omit. Both bounds are configuration rather than constants
/// scattered through the parser.
///
/// The defaults sit far above any realistic chunk rather than close to one: the bound
/// exists to stop unbounded growth, not to police message size, and a limit that fired
/// on legitimate traffic would be worse than no limit at all.
struct SSEParserLimits: Sendable, Equatable {
    /// The longest single line, before its terminating newline.
    var maxLineBytes: Int
    /// The most `data:` content one event may accumulate, across all of its lines.
    var maxEventBytes: Int

    init(maxLineBytes: Int, maxEventBytes: Int) {
        self.maxLineBytes = maxLineBytes
        self.maxEventBytes = maxEventBytes
    }

    static let `default` = SSEParserLimits(
        maxLineBytes: 1 << 20,
        maxEventBytes: 4 << 20
    )
}

enum SSEParserError: Error, Equatable {
    /// A line's bytes are not valid UTF-8.
    ///
    /// Fatal rather than replaced with U+FFFD: a substituted character is a silent
    /// corruption of the model's output, and the notes forbid handing half-decoded
    /// content upward as though it were valid text (`Provider 与模型.md:61`).
    case invalidUTF8
    /// A framing violation. Narrow by design — see `SSEParser`.
    case malformedFrame(String)
    /// The stream ended without reaching its terminator.
    ///
    /// A truncated answer reported as a clean one is the failure the notes single out
    /// (`Provider 与模型.md:62`).
    case unterminatedStream
    /// A reassembly buffer reached its bound.
    case bufferLimitExceeded(limit: Int)
}

/// Turns a byte stream into SSE events.
///
/// **Byte-driven, not line-driven and not string-driven.** Bytes accumulate into a line
/// buffer and are decoded only once the line boundary is known, which is what makes a
/// multi-byte character split across two network chunks come out correct rather than as
/// two replacement characters. Decoding per chunk would look right on ASCII and corrupt
/// every emoji and every non-Latin script.
///
/// Pure and synchronous: it takes bytes and gives back elements, with no clock, no
/// network and no concurrency. Every boundary this increment has to get right — split
/// characters, split events, CRLF, comments, the terminator — is reachable from a test
/// by feeding bytes.
///
/// **What `malformedFrame` means here.** The SSE grammar is deliberately permissive: a
/// line with no colon is a field with an empty value, an unrecognised field is ignored,
/// and a line beginning with a colon is a comment. So very little input is actually
/// unparseable, and this parser does not invent strictness the protocol does not have.
/// A framing failure is one of exactly two things: a NUL byte, which cannot appear in an
/// event stream, or a buffer over its bound.
struct SSEParser: Sendable {

    /// The terminator DeepSeek and OpenAI both send as a `data:` payload.
    static let doneSentinel = "[DONE]"

    private let limits: SSEParserLimits

    // MARK: - Reassembly state

    private var lineBuffer: [UInt8] = []
    private var dataBuffer = ""
    private var dataByteCount = 0
    private var eventName: String?
    /// Set by a lone CR, so the LF of a CRLF pair is not read as a blank line.
    private var awaitingLineFeed = false
    private var sawDone = false

    init(limits: SSEParserLimits = .default) {
        self.limits = limits
    }

    /// Whether the terminator has been reached.
    ///
    /// Once true, every later byte is ignored — see `consume`.
    var reachedTerminator: Bool { sawDone }

    // MARK: - Consumption

    /// Feeds bytes and returns whatever they completed.
    ///
    /// After the terminator, all further input is ignored rather than rejected. A stream
    /// that sends a trailing newline after `data: [DONE]` is not malformed, and treating
    /// it as such would turn harmless input into a failed answer.
    ///
    /// Throws on the first failure, and abandons the rest of the chunk. Elements from
    /// this chunk that were already produced are not returned — deliberately: the stream
    /// is failing, and the caller keeps the elements it was given by earlier calls. The
    /// alternative would be to report a failure *and* hand back content, which invites a
    /// caller to treat a truncated answer as a whole one.
    mutating func consume(_ bytes: some Sequence<UInt8>) throws -> [SSEStreamElement] {
        var produced: [SSEStreamElement] = []
        for byte in bytes {
            if sawDone { break }
            try feed(byte, into: &produced)
        }
        return produced
    }

    /// Declares the end of input.
    ///
    /// Fails unless the terminator was reached, which is what distinguishes a stream that
    /// finished from one that stopped.
    mutating func finish() throws {
        guard sawDone else { throw SSEParserError.unterminatedStream }
    }

    // MARK: - Byte handling

    private mutating func feed(_ byte: UInt8, into produced: inout [SSEStreamElement]) throws {
        // Ahead of the decoder because NUL *is* valid UTF-8 and would otherwise be
        // carried into a string and parsed as an ordinary character.
        if byte == 0x00 {
            throw SSEParserError.malformedFrame("a NUL byte cannot appear in an event stream")
        }

        if byte == 0x0A { // LF
            if awaitingLineFeed {
                // The second half of a CRLF. The line already ended at the CR.
                awaitingLineFeed = false
                return
            }
            try endLine(into: &produced)
            return
        }

        awaitingLineFeed = false

        if byte == 0x0D { // CR
            // A lone CR terminates a line; a CR followed by LF terminates it once.
            try endLine(into: &produced)
            awaitingLineFeed = true
            return
        }

        lineBuffer.append(byte)
        guard lineBuffer.count <= limits.maxLineBytes else {
            throw SSEParserError.bufferLimitExceeded(limit: limits.maxLineBytes)
        }
    }

    private mutating func endLine(into produced: inout [SSEStreamElement]) throws {
        let line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        try interpret(line, into: &produced)
    }

    // MARK: - Line interpretation

    private mutating func interpret(_ bytes: [UInt8], into produced: inout [SSEStreamElement]) throws {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            throw SSEParserError.invalidUTF8
        }

        if line.isEmpty {
            dispatch(into: &produced)
            return
        }

        // A comment, which is also how a provider keeps a connection alive. Consumed
        // rather than treated as malformed — the notes are explicit that a heartbeat
        // must be recognised and consumed, not counted as a bad event
        // (`Provider 与模型.md:63`). It produces no element, which is exactly why a
        // keep-alive cannot be mistaken for model output.
        if line.hasPrefix(":") { return }

        let field: Substring
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            let rest = line[line.index(after: colon)...]
            // One leading space is part of the separator, not the value. Further
            // spaces are the value's own.
            value = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        } else {
            // The grammar allows a bare field name, meaning an empty value.
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data":
            dataByteCount += value.utf8.count + 1
            guard dataByteCount <= limits.maxEventBytes else {
                throw SSEParserError.bufferLimitExceeded(limit: limits.maxEventBytes)
            }
            dataBuffer += value
            dataBuffer += "\n"
        case "event":
            eventName = value
        default:
            // `id`, `retry` and anything a provider invents. Ignored rather than
            // rejected: an unknown field is not an error, and refusing the stream over
            // one would be this parser inventing a rule the protocol does not have.
            break
        }
    }

    private mutating func dispatch(into produced: inout [SSEStreamElement]) {
        defer {
            dataBuffer = ""
            dataByteCount = 0
            eventName = nil
        }

        // A blank line with no data behind it dispatches nothing. Heartbeats are often
        // exactly this shape, so it must be silent rather than an empty event.
        guard !dataBuffer.isEmpty else { return }

        var data = dataBuffer
        if data.hasSuffix("\n") { data.removeLast() }

        if data == Self.doneSentinel {
            sawDone = true
            produced.append(.done)
            return
        }
        produced.append(.event(SSEEvent(name: eventName, data: data)))
    }
}
