import Foundation

struct GLMChatCompletionStreamChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            var content: String?
            var reasoning_content: String?
            var tool_calls: [ToolCallDelta]?
        }

        var delta: Delta?
        var finish_reason: String?
    }

    struct ToolCallDelta: Decodable, Sendable {
        struct Function: Decodable, Sendable {
            var name: String?
            var arguments: String?
        }

        var index: Int
        var id: String?
        var type: String?
        var function: Function?
    }

    struct Usage: Decodable, Sendable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var total_tokens: Int?
    }

    var choices: [Choice]?
    var usage: Usage?
}

struct GLMChatCompletionStreamDecoder {
    struct Output {
        var events: [ProviderStreamEvent]
        var madeProgress: Bool
    }

    private struct ToolCallAssembly {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var toolCalls: [Int: ToolCallAssembly] = [:]

    mutating func consume(_ payload: String) throws -> Output {
        let chunk: GLMChatCompletionStreamChunk
        do {
            chunk = try JSONDecoder().decode(GLMChatCompletionStreamChunk.self, from: Data(payload.utf8))
        } catch {
            throw ProviderError.malformedResponse("a GLM streaming chunk did not match the expected shape")
        }

        let choice = chunk.choices?.first
        let delta = choice?.delta
        let fragments = delta?.tool_calls ?? []
        for fragment in fragments {
            var call = toolCalls[fragment.index, default: ToolCallAssembly()]
            if let id = fragment.id, !id.isEmpty { call.id = id }
            if let name = fragment.function?.name, !name.isEmpty { call.name = name }
            if let arguments = fragment.function?.arguments { call.arguments += arguments }
            toolCalls[fragment.index] = call
        }

        var events: [ProviderStreamEvent] = []
        if let reasoning = delta?.reasoning_content, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let content = delta?.content, !content.isEmpty {
            events.append(.textDelta(content))
        }

        if choice?.finish_reason != nil {
            events.append(contentsOf: try finishToolCalls().map(ProviderStreamEvent.toolCall))
        }
        if let usage = chunk.usage {
            events.append(.usage(ProviderTokenUsage(
                promptTokens: usage.prompt_tokens,
                completionTokens: usage.completion_tokens,
                totalTokens: usage.total_tokens
            )))
        }
        if let finishReason = choice?.finish_reason {
            events.append(.finish(Self.finishReason(from: finishReason)))
        }

        return Output(
            events: events,
            madeProgress: !(delta?.content ?? "").isEmpty
                || !(delta?.reasoning_content ?? "").isEmpty
                || !fragments.isEmpty
        )
    }

    mutating func finish() throws -> [ProviderStreamEvent] {
        try finishToolCalls().map(ProviderStreamEvent.toolCall)
    }

    private static func finishReason(from wire: String?) -> FinishReason {
        switch wire {
        case "stop": return .stop
        case "length": return .length
        case "content_filter", "sensitive": return .contentFilter
        case "tool_calls": return .toolCalls
        case "network_error", "insufficient_system_resource", "aborted": return .interrupted
        case .some(let reason): return .unknown(reason)
        case .none: return .unknown("absent")
        }
    }

    private mutating func finishToolCalls() throws -> [ProviderToolCall] {
        let calls = try toolCalls.keys.sorted().map { index -> ProviderToolCall in
            guard let call = toolCalls[index], !call.id.isEmpty, !call.name.isEmpty else {
                throw ProviderError.malformedResponse("a streamed GLM tool call was missing its id or function name")
            }
            return ProviderToolCall(
                id: call.id,
                index: index,
                name: call.name,
                argumentsJSON: call.arguments
            )
        }
        toolCalls.removeAll(keepingCapacity: false)
        return calls
    }
}