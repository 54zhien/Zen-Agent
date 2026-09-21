import Foundation

/// What the caller asked for, in Zen's vocabulary rather than a Provider's.
///
/// The Runtime and Persistence see only this. A DeepSeek DTO never leaves the adapter
/// directory, which is what keeps a second Provider from having to be expressed as a
/// special case of the first.
struct ProviderChatRequest: Sendable, Equatable {
    var modelID: ModelID
    var messages: [ProviderChatMessage]
    var tools: [ProviderToolDefinition]

    init(
        modelID: ModelID,
        messages: [ProviderChatMessage],
        tools: [ProviderToolDefinition] = []
    ) {
        self.modelID = modelID
        self.messages = messages
        self.tools = tools
    }
}

struct ProviderToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var parameters: JSONValue
}

struct ProviderToolCall: Sendable, Equatable {
    var id: String
    var index: Int
    var name: String
    var argumentsJSON: String
}

/// A provider-neutral message. Tool calls and their results remain structured so a
/// continuation can be encoded as protocol messages instead of being flattened into
/// user-visible text.
enum ProviderChatMessage: Sendable, Equatable {
    case system(String)
    case user(String)
    case assistant(
        content: String?,
        reasoning: String?,
        toolCalls: [ProviderToolCall]
    )
    case toolResult(
        toolCallID: String,
        content: String
    )
}

/// What came back, normalised.
struct ProviderResponse: Sendable, Equatable {
    /// The provider's own id for this response, kept so a later diagnostic can refer to
    /// it without re-deriving anything.
    var id: String
    var text: String
    /// Visible reasoning, when the provider offers it.
    ///
    /// Only what the provider explicitly exposes for display. Hidden chain-of-thought is
    /// not a response field and must not be smuggled into one — see
    /// `消息与数据.md:49` for why the distinction matters to what the UI may show.
    var reasoning: String?
    /// Complete tool calls in a non-streaming response, when present.
    var toolCalls: [ProviderToolCall]
    var finishReason: FinishReason
    var usage: ProviderTokenUsage?

    init(
        id: String,
        text: String,
        reasoning: String?,
        toolCalls: [ProviderToolCall] = [],
        finishReason: FinishReason,
        usage: ProviderTokenUsage?
    ) {
        self.id = id
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// Why generation stopped.
///
/// An open case for values not seen yet: a Provider that adds a stop reason must not
/// cause the whole response to fail to decode, and it must not be silently reported as
/// a clean stop either.
enum FinishReason: Sendable, Equatable {
    case stop
    case length
    case contentFilter
    case toolCalls
    case unknown(String)
}

struct ProviderTokenUsage: Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
}

enum ProviderStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(ProviderToolCall)
    case finish(FinishReason)
    case usage(ProviderTokenUsage)
}
