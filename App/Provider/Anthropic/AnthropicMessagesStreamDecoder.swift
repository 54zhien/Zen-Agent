import Foundation

enum AnthropicMessagesEventResult: Sendable {
    case ignored
    case output([ProviderStreamEvent], madeProgress: Bool)
    case completed(usage: ProviderTokenUsage?, finishReason: FinishReason)
    case failed(code: String?, message: String?)
}

struct AnthropicMessagesStreamDecoder: Sendable {
    private struct ContentBlockDraft: Sendable {
        enum Kind: Sendable {
            case text
            case toolUse(id: String, name: String, initialInputJSON: String)
        }

        let kind: Kind
        var partialJSON = ""
    }

    private var contentBlocks: [Int: ContentBlockDraft] = [:]
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopReason: String?
    private var sawMessageStart = false

    mutating func consume(_ event: SSEEvent) throws -> AnthropicMessagesEventResult {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                throw ProviderError.malformedResponse("an Anthropic Messages event was not a JSON object")
            }
            object = decoded
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.malformedResponse("an Anthropic Messages event was not valid JSON")
        }

        guard let type = object["type"] as? String,
              event.name == nil || event.name == type else {
            throw ProviderError.malformedResponse("an Anthropic Messages event name did not match its type")
        }

        switch type {
        case "message_start":
            guard !sawMessageStart,
                  let message = object["message"] as? [String: Any] else {
                throw ProviderError.malformedResponse("an Anthropic message_start event was incomplete")
            }
            sawMessageStart = true
            let usage = message["usage"] as? [String: Any]
            inputTokens = usage?["input_tokens"] as? Int
            outputTokens = usage?["output_tokens"] as? Int
            return .ignored

        case "content_block_start":
            return try startContentBlock(object)

        case "content_block_delta":
            return try appendContentDelta(object)

        case "content_block_stop":
            return try stopContentBlock(object)

        case "message_delta":
            guard let delta = object["delta"] as? [String: Any] else {
                throw ProviderError.malformedResponse("an Anthropic message_delta event had no delta")
            }
            if let reason = delta["stop_reason"] as? String { stopReason = reason }
            if let usage = object["usage"] as? [String: Any] {
                if let count = usage["input_tokens"] as? Int { inputTokens = count }
                if let count = usage["output_tokens"] as? Int { outputTokens = count }
            }
            return .ignored

        case "message_stop":
            guard sawMessageStart else {
                throw ProviderError.malformedResponse("an Anthropic message_stop event arrived before message_start")
            }
            guard contentBlocks.isEmpty else {
                throw ProviderError.malformedResponse("an Anthropic message_stop event left a content block unfinished")
            }
            let total = inputTokens.flatMap { input in outputTokens.map { input + $0 } }
            let usage = (inputTokens != nil || outputTokens != nil)
                ? ProviderTokenUsage(promptTokens: inputTokens, completionTokens: outputTokens, totalTokens: total)
                : nil
            return .completed(usage: usage, finishReason: Self.finishReason(from: stopReason))

        case "error":
            let error = object["error"] as? [String: Any]
            return .failed(code: error?["type"] as? String, message: error?["message"] as? String)

        case "ping":
            return .ignored

        default:
            // Anthropic may add event types without changing the SSE envelope.
            return .ignored
        }
    }

    private mutating func startContentBlock(_ object: [String: Any]) throws -> AnthropicMessagesEventResult {
        guard let index = object["index"] as? Int,
              let block = object["content_block"] as? [String: Any],
              let type = block["type"] as? String,
              contentBlocks[index] == nil else {
            throw ProviderError.malformedResponse("an Anthropic content_block_start event was incomplete")
        }

        switch type {
        case "text":
            contentBlocks[index] = ContentBlockDraft(kind: .text)
            if let text = block["text"] as? String, !text.isEmpty {
                return .output([.textDelta(text)], madeProgress: true)
            }
            return .ignored

        case "tool_use":
            guard let id = block["id"] as? String,
                  let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else {
                throw ProviderError.malformedResponse("an Anthropic tool_use block was incomplete")
            }
            contentBlocks[index] = ContentBlockDraft(
                kind: .toolUse(id: id, name: name, initialInputJSON: try Self.encode(input))
            )
            return .ignored

        case "thinking", "redacted_thinking":
            throw ProviderError.malformedResponse(
                "Anthropic returned a thinking block that this stateless adapter cannot preserve"
            )

        default:
            throw ProviderError.malformedResponse("Anthropic returned an unsupported content block")
        }
    }

    private mutating func appendContentDelta(_ object: [String: Any]) throws -> AnthropicMessagesEventResult {
        guard let index = object["index"] as? Int,
              let delta = object["delta"] as? [String: Any],
              var block = contentBlocks[index],
              let type = delta["type"] as? String else {
            throw ProviderError.malformedResponse("an Anthropic content_block_delta event was incomplete")
        }

        switch type {
        case "text_delta":
            guard case .text = block.kind, let text = delta["text"] as? String else {
                throw ProviderError.malformedResponse("an Anthropic text delta did not match its content block")
            }
            return text.isEmpty ? .ignored : .output([.textDelta(text)], madeProgress: true)

        case "input_json_delta":
            guard case .toolUse = block.kind,
                  let partial = delta["partial_json"] as? String else {
                throw ProviderError.malformedResponse("an Anthropic input JSON delta did not match its tool block")
            }
            block.partialJSON += partial
            contentBlocks[index] = block
            return .output([], madeProgress: !partial.isEmpty)

        case "thinking_delta", "signature_delta":
            throw ProviderError.malformedResponse(
                "Anthropic returned thinking data that this stateless adapter cannot preserve"
            )

        default:
            throw ProviderError.malformedResponse("Anthropic returned an unsupported content block delta")
        }
    }

    private mutating func stopContentBlock(_ object: [String: Any]) throws -> AnthropicMessagesEventResult {
        guard let index = object["index"] as? Int,
              let block = contentBlocks.removeValue(forKey: index) else {
            throw ProviderError.malformedResponse("an Anthropic content_block_stop event had no matching block")
        }

        guard case .toolUse(let id, let name, let initialInputJSON) = block.kind else {
            return .ignored
        }
        let argumentsJSON = block.partialJSON.isEmpty ? initialInputJSON : block.partialJSON
        guard let data = argumentsJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ProviderError.malformedResponse("an Anthropic tool_use block ended with incomplete JSON input")
        }
        return .output([
            .toolCall(ProviderToolCall(
                id: id,
                index: index,
                name: name,
                argumentsJSON: argumentsJSON
            )),
        ], madeProgress: true)
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProviderError.malformedResponse("an Anthropic tool input was not valid UTF-8")
            }
            return text
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.malformedResponse("an Anthropic tool input could not be encoded")
        }
    }

    private static func finishReason(from wire: String?) -> FinishReason {
        switch wire {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolCalls
        case "refusal": return .contentFilter
        case .some(let other): return .unknown(other)
        case .none: return .interrupted
        }
    }
}
