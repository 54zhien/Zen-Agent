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

    struct Usage: Decodable, Sendable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var total_tokens: Int?
    }

    var id: String?
    var choices: [Choice]?
    var usage: Usage?
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
