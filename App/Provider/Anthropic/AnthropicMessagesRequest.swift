import Foundation

enum AnthropicMessagesRequest {
    static func body(for request: ProviderChatRequest, maxOutputTokens: Int) throws -> Data {
        var system: [[String: Any]] = []
        var messages: [[String: Any]] = []
        var lastMessageContainsToolResults = false

        for message in request.messages {
            switch message {
            case .system(let text):
                system.append(["type": "text", "text": text])
                lastMessageContainsToolResults = false

            case .user(let text):
                messages.append(["role": "user", "content": text])
                lastMessageContainsToolResults = false

            case .assistant(let content, let reasoning, let toolCalls):
                guard reasoning == nil || reasoning?.isEmpty == true else {
                    throw ProviderError.invalidRequest(
                        "Anthropic Messages cannot replay the provider-neutral reasoning transcript"
                    )
                }

                var blocks: [[String: Any]] = []
                if let content, !content.isEmpty {
                    blocks.append(["type": "text", "text": content])
                }
                for call in toolCalls.sorted(by: { $0.index < $1.index }) {
                    guard let input = try foundationObject(from: call.argumentsJSON) as? [String: Any] else {
                        throw ProviderError.invalidRequest("a tool call input must be a JSON object")
                    }
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input,
                    ])
                }
                if !blocks.isEmpty {
                    messages.append(["role": "assistant", "content": blocks])
                }
                lastMessageContainsToolResults = false

            case .toolResult(let toolCallID, let content):
                let result: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolCallID,
                    "content": content,
                ]
                if lastMessageContainsToolResults, let last = messages.indices.last,
                   var blocks = messages[last]["content"] as? [[String: Any]] {
                    blocks.append(result)
                    messages[last]["content"] = blocks
                } else {
                    messages.append(["role": "user", "content": [result]])
                    lastMessageContainsToolResults = true
                }
            }
        }

        var object: [String: Any] = [
            "model": request.modelID.rawValue,
            "max_tokens": maxOutputTokens,
            "messages": messages,
            "stream": true,
            "thinking": ["type": "disabled"],
        ]
        if !system.isEmpty { object["system"] = system }
        if !request.tools.isEmpty {
            object["tools"] = try request.tools.map { tool in
                guard let schema = try foundationObject(from: tool.parameters) as? [String: Any] else {
                    throw ProviderError.invalidRequest("a tool input schema must be a JSON object")
                }
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": schema,
                ] as [String: Any]
            }
        }

        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw ProviderError.invalidRequest("the Anthropic Messages request body could not be encoded")
        }
    }

    private static func foundationObject(from value: JSONValue) throws -> Any {
        do {
            let encoded = try JSONEncoder().encode(value)
            return try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        } catch {
            throw ProviderError.invalidRequest("a tool input schema could not be encoded")
        }
    }

    private static func foundationObject(from json: String) throws -> Any {
        guard let data = json.data(using: .utf8) else {
            throw ProviderError.invalidRequest("a tool call input was not valid UTF-8")
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProviderError.invalidRequest("a tool call input was not valid JSON")
        }
    }
}
