import Foundation

/// DeepSeek's wire format. **Private to this directory.**
///
/// These types exist so the shape of DeepSeek's JSON is expressed once, and so nothing
/// above the adapter has to know `reasoning_content` is snake_case or that `choices` is
/// an array that is normally one element long. A DTO that escaped would make the next
/// Provider's differences everybody's problem, and would make DeepSeek's field names
/// part of Zen's persisted data.
///
/// Field names are the wire's, deliberately. Renaming them to Swift style here would
/// make the mapping invisible, and the mapping is the one thing worth being able to
/// read.

struct DeepSeekChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    /// `false` in this increment. Streaming is its own increment, and a flag that could
    /// switch the response into a shape nothing here can parse is a flag worth not
    /// having yet.
    var stream: Bool
}

/// Token accounting. The same shape in a streamed and a non-streamed response, so it is
/// declared once rather than nested inside each.
struct DeepSeekUsage: Decodable, Sendable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
}

struct DeepSeekChatResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            var role: String?
            var content: String?
            /// DeepSeek's visible reasoning, when the model is in thinking mode.
            ///
            /// Optional because the field is absent in non-thinking responses, and
            /// nothing here may assume a mode.
            var reasoning_content: String?
        }

        var index: Int?
        var message: Message?
        var finish_reason: String?
    }

    var id: String?
    var choices: [Choice]?
    var usage: DeepSeekUsage?
}

/// One chunk of a streamed completion.
///
/// The differences from `DeepSeekChatResponse` are the point of having a second type:
/// a streamed chunk carries a `delta` rather than a whole `message`, and everything in
/// it is optional because most chunks carry only one of them.
///
/// **Every field is optional, and that is not laziness.** DeepSeek's last chunk before
/// the terminator typically carries no content at all — one choice, an empty delta, a
/// non-empty `finish_reason` — and its usage arrives only on that final chunk. A decoder
/// that required content would fail on every stream at the moment it succeeded, and a
/// decoder that treated a contentless chunk as malformed would throw away the only
/// message that says the generation finished.
struct DeepSeekStreamChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            /// Present on the first chunk only, when it is present at all.
            var role: String?
            var content: String?
            /// Visible reasoning, which arrives as deltas of its own interleaved with
            /// the answer's — not as a separate phase, and not always before it.
            var reasoning_content: String?
        }

        var index: Int?
        var delta: Delta?
        var finish_reason: String?
    }

    var id: String?
    var choices: [Choice]?
    var usage: DeepSeekUsage?
}

/// The error envelope DeepSeek returns alongside a non-2xx status.
///
/// Used for a controlled diagnostic message only. The text of this never becomes a
/// `ProviderError` case — see `ProviderError`.
struct DeepSeekErrorResponse: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var message: String?
        var type: String?
        var code: String?
    }

    var error: Body?
}
