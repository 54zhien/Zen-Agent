import Foundation

/// GLM's Chat Completions request stays inside this adapter.
struct GLMChatCompletionRequest: Encodable, Sendable {
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
        var tool_calls: [ToolCall]?
        var tool_call_id: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let content {
                try container.encode(content, forKey: .content)
            } else if role == "assistant" {
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

    struct ToolCall: Encodable, Sendable {
        struct Function: Encodable, Sendable {
            var name: String
            var arguments: String
        }

        var id: String
        var type: String
        var function: Function
    }

    struct Thinking: Encodable, Sendable {
        var type: String
    }

    var model: String
    var messages: [Message]
    var stream: Bool
    var thinking: Thinking
    var reasoning_effort: String?
    var tool_stream: Bool?
    var tools: [Tool]?

    init(request: ProviderChatRequest, thinkingEffort: ThinkingEffort?) {
        model = request.modelID.rawValue
        messages = request.messages.map(Self.makeMessage)
        stream = true
        thinking = Thinking(type: "enabled")
        reasoning_effort = thinkingEffort?.rawValue
        tool_stream = request.tools.isEmpty ? nil : true
        tools = request.tools.isEmpty ? nil : request.tools.map {
            Tool(
                type: "function",
                function: Function(
                    name: $0.name,
                    description: $0.description,
                    parameters: $0.parameters
                )
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case thinking
        case reasoning_effort
        case tool_stream
        case tools
    }

    static func body(
        for request: ProviderChatRequest,
        thinkingEffort: ThinkingEffort?
    ) throws -> Data {
        try JSONEncoder().encode(Self(request: request, thinkingEffort: thinkingEffort))
    }

    private static func makeMessage(_ message: ProviderChatMessage) -> Message {
        switch message {
        case .system(let content):
            Message(role: "system", content: content, reasoning_content: nil, tool_calls: nil, tool_call_id: nil)
        case .user(let content):
            Message(role: "user", content: content, reasoning_content: nil, tool_calls: nil, tool_call_id: nil)
        case .assistant(let content, let reasoning, let toolCalls):
            Message(
                role: "assistant",
                content: content,
                reasoning_content: reasoning,
                tool_calls: toolCalls.isEmpty ? nil : toolCalls.map {
                    ToolCall(
                        id: $0.id,
                        type: "function",
                        function: ToolCall.Function(name: $0.name, arguments: $0.argumentsJSON)
                    )
                },
                tool_call_id: nil
            )
        case .toolResult(let toolCallID, let content):
            Message(
                role: "tool",
                content: content,
                reasoning_content: nil,
                tool_calls: nil,
                tool_call_id: toolCallID
            )
        }
    }
}