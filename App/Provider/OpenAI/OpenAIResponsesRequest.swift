import Foundation

enum OpenAIResponsesRequest {
    static func body(for request: ProviderChatRequest) throws -> Data {
        var object: [String: Any] = [
            "model": request.modelID.rawValue,
            "input": try inputItems(from: request.messages),
            "stream": true,
            "store": false,
            "reasoning": ["effort": "none"],
        ]
        if !request.tools.isEmpty {
            object["tools"] = try request.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": try foundationObject(from: tool.parameters),
                ] as [String: Any]
            }
        }

        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw ProviderError.invalidRequest("the Responses request body could not be encoded")
        }
    }

    private static func inputItems(from messages: [ProviderChatMessage]) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system(let content):
                input.append(["role": "system", "content": content])
            case .user(let content):
                input.append(["role": "user", "content": content])
            case .userContent(let parts):
                input.append([
                    "role": "user",
                    "content": parts.map { part in
                        switch part {
                        case .text(let text):
                            return ["type": "input_text", "text": text]
                        case .image(let mediaType, let data):
                            return [
                                "type": "input_image",
                                "image_url": "data:\(mediaType);base64,\(data.base64EncodedString())",
                            ]
                        }
                    },
                ])
            case .assistant(let content, let reasoning, let toolCalls):
                guard reasoning == nil || reasoning?.isEmpty == true else {
                    throw ProviderError.invalidRequest(
                        "OpenAI Responses does not accept the provider-neutral reasoning transcript"
                    )
                }
                if let content, !content.isEmpty {
                    input.append(["role": "assistant", "content": content])
                }
                for call in toolCalls.sorted(by: { $0.index < $1.index }) {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON,
                    ])
                }
            case .toolResult(let toolCallID, let content):
                input.append([
                    "type": "function_call_output",
                    "call_id": toolCallID,
                    "output": content,
                ])
            }
        }
        return input
    }

    private static func foundationObject(from value: JSONValue) throws -> Any {
        let encoded = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
    }
}
