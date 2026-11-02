import Foundation

enum OpenAIResponsesEventResult: Sendable {
    case ignored
    case output([ProviderStreamEvent], madeProgress: Bool)
    case completed(usage: ProviderTokenUsage?, finishReason: FinishReason)
    case incomplete(usage: ProviderTokenUsage?, finishReason: FinishReason)
    case failed(code: String?, message: String?)
}

struct OpenAIResponsesStreamDecoder: Sendable {
    private struct FunctionCallDraft: Sendable {
        let itemID: String
        let callID: String
        let name: String
        var arguments: String
        var emitted = false
    }

    private var callsByOutputIndex: [Int: FunctionCallDraft] = [:]
    private(set) var hasFunctionCalls = false

    mutating func consume(_ event: SSEEvent) throws -> OpenAIResponsesEventResult {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                throw ProviderError.malformedResponse("a Responses event was not a JSON object")
            }
            object = decoded
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.malformedResponse("a Responses event was not valid JSON")
        }

        guard let type = object["type"] as? String,
              event.name == type else {
            throw ProviderError.malformedResponse("a Responses event name did not match its type")
        }

        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = object["delta"] as? String else {
                throw ProviderError.malformedResponse("a Responses text delta had no text")
            }
            return delta.isEmpty ? .ignored : .output([.textDelta(delta)], madeProgress: true)

        case "response.output_item.added":
            return try addOutputItem(object)

        case "response.function_call_arguments.delta":
            return try appendArguments(object)

        case "response.function_call_arguments.done":
            return try finishArguments(object)

        case "response.completed":
            guard let response = object["response"] as? [String: Any] else {
                throw ProviderError.malformedResponse("a completed Responses event had no response")
            }
            guard callsByOutputIndex.values.allSatisfy(\.emitted) else {
                throw ProviderError.malformedResponse("a completed Responses event contained an unfinished function call")
            }
            return .completed(
                usage: Self.usage(from: response["usage"]),
                finishReason: hasFunctionCalls ? .toolCalls : .stop
            )

        case "response.incomplete":
            guard let response = object["response"] as? [String: Any] else {
                throw ProviderError.malformedResponse("an incomplete Responses event had no response")
            }
            let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
            let finishReason: FinishReason
            if let reason {
                switch reason {
                case "max_output_tokens": finishReason = .length
                case "content_filter": finishReason = .contentFilter
                default: finishReason = .unknown(reason)
                }
            } else {
                finishReason = .interrupted
            }
            return .incomplete(
                usage: Self.usage(from: response["usage"]),
                finishReason: finishReason
            )

        case "response.failed", "error":
            if type == "error" {
                return .failed(
                    code: object["code"] as? String,
                    message: object["message"] as? String
                )
            }
            let error = (object["response"] as? [String: Any])?["error"] as? [String: Any]
            return .failed(code: error?["code"] as? String, message: error?["message"] as? String)

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            throw ProviderError.malformedResponse(
                "OpenAI returned reasoning output that this stateless adapter cannot preserve"
            )

        case "response.created", "response.queued", "response.in_progress",
             "response.content_part.added", "response.content_part.done",
             "response.output_text.done", "response.output_item.done",
             "response.refusal.done":
            return .ignored

        default:
            throw ProviderError.malformedResponse("an unsupported Responses event was received")
        }
    }

    private mutating func addOutputItem(_ object: [String: Any]) throws -> OpenAIResponsesEventResult {
        guard let index = object["output_index"] as? Int,
              let item = object["item"] as? [String: Any],
              let type = item["type"] as? String else {
            throw ProviderError.malformedResponse("a Responses output item was incomplete")
        }
        switch type {
        case "message":
            return .ignored
        case "reasoning":
            throw ProviderError.malformedResponse(
                "OpenAI returned reasoning output that this stateless adapter cannot preserve"
            )
        case "function_call":
            guard let itemID = item["id"] as? String,
                  let callID = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  callsByOutputIndex[index] == nil else {
                throw ProviderError.malformedResponse("a Responses function call item was incomplete")
            }
            callsByOutputIndex[index] = FunctionCallDraft(
                itemID: itemID,
                callID: callID,
                name: name,
                arguments: arguments
            )
            hasFunctionCalls = true
            return .output([], madeProgress: true)
        default:
            throw ProviderError.malformedResponse("an unsupported Responses output item was received")
        }
    }

    private mutating func appendArguments(_ object: [String: Any]) throws -> OpenAIResponsesEventResult {
        guard let index = object["output_index"] as? Int,
              let itemID = object["item_id"] as? String,
              let delta = object["delta"] as? String,
              var call = callsByOutputIndex[index],
              call.itemID == itemID,
              !call.emitted else {
            throw ProviderError.malformedResponse("function call arguments did not match their output item")
        }
        call.arguments += delta
        callsByOutputIndex[index] = call
        return .output([], madeProgress: !delta.isEmpty)
    }

    private mutating func finishArguments(_ object: [String: Any]) throws -> OpenAIResponsesEventResult {
        guard let index = object["output_index"] as? Int,
              let itemID = object["item_id"] as? String,
              let arguments = object["arguments"] as? String,
              var call = callsByOutputIndex[index],
              call.itemID == itemID,
              !call.emitted else {
            throw ProviderError.malformedResponse("final function call arguments did not match their output item")
        }
        call.arguments = arguments
        call.emitted = true
        callsByOutputIndex[index] = call
        return .output([
            .toolCall(ProviderToolCall(
                id: call.callID,
                index: index,
                name: call.name,
                argumentsJSON: call.arguments
            )),
        ], madeProgress: true)
    }

    private static func usage(from value: Any?) -> ProviderTokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        return ProviderTokenUsage(
            promptTokens: usage["input_tokens"] as? Int,
            completionTokens: usage["output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int
        )
    }
}
