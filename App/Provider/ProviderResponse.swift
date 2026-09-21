import Foundation

/// What the caller asked for, in Zen's vocabulary rather than a Provider's.
///
/// The Runtime and Persistence see only this. A DeepSeek DTO never leaves the adapter
/// directory, which is what keeps a second Provider from having to be expressed as a
/// special case of the first.
struct ProviderChatRequest: Sendable, Equatable {
    var modelID: ModelID
    var messages: [ProviderChatMessage]
}

struct ProviderChatMessage: Sendable, Equatable {
    var role: ProviderChatRole
    var content: String
}

enum ProviderChatRole: String, Sendable, Codable {
    case system
    case user
    case assistant
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
    var finishReason: FinishReason
    var usage: ProviderTokenUsage?
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
    case finish(FinishReason)
    case usage(ProviderTokenUsage)
}
