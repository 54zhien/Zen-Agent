import Foundation

/// DeepSeek's wire format. **Private to this directory.**
///
/// These types exist so the shape of DeepSeek's JSON is expressed once, and so nothing
/// above the adapter has to know `reasoning_content` is snake_case or that tool calls
/// use a nested `function` object. A DTO that escaped would make the next Provider's
/// differences everybody's problem, and would make DeepSeek's field names part of Zen's
/// persisted data.
struct DeepSeekChatRequest: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    struct Tool: Encodable, Sendable {
        var type: String
        var function: Function
    }

    struct Message: Encodable, Sendable {
        var role: String
        var content: String?
        var reasoning_content: String?
        var tool_calls: [DeepSeekToolCall]?
        var tool_call_id: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let content {
                try container.encode(content, forKey: .content)
            } else if role == "assistant" {
                // DeepSeek's tool-call continuation shape uses an explicit null
                // assistant content alongside the tool_calls field.
                try container.encodeNil(forKey: .content)
            }
            try container.encodeIfPresent(reasoning_content, forKey: .reasoning_content)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        }

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoning_content
            case tool_calls
            case tool_call_id
        }
    }

    var model: String
    var messages: [Message]
    var tools: [Tool]
    var stream: Bool

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        // DeepSeek treats tools as optional. Omitting an empty list preserves the
        // Stage 1 plain-chat wire shape while still encoding the real tool surface.
        if !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
        }
        try container.encode(stream, forKey: .stream)
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case stream
    }
}

struct DeepSeekToolCallFunction: Codable, Sendable {
    var name: String?
    var arguments: String?
}

struct DeepSeekToolCall: Codable, Sendable {
    var id: String?
    var type: String?
    var function: DeepSeekToolCallFunction?
}

/// A streamed tool-call fragment carries its ordering index alongside the optional
/// fields. The first fragment normally carries id/name and later fragments only carry
/// more argument text.
struct DeepSeekToolCallDelta: Decodable, Sendable {
    var index: Int?
    var id: String?
    var type: String?
    var function: DeepSeekToolCallFunction?
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
            var reasoning_content: String?
            var tool_calls: [DeepSeekToolCall]?
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
struct DeepSeekStreamChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            /// Present on the first chunk only, when it is present at all.
            var role: String?
            var content: String?
            /// Visible reasoning, which arrives as deltas of its own interleaved with
            /// the answer's — not as a separate phase, and not always before it.
            var reasoning_content: String?
            var tool_calls: [DeepSeekToolCallDelta]?
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
struct DeepSeekErrorResponse: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var message: String?
        var type: String?
        var code: String?
    }

    var error: Body?
}
