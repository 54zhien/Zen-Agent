import Foundation

enum PromptHistoryRole: Sendable, Equatable {
    case user
    case assistant

    var providerRole: ProviderChatRole {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        }
    }
}

struct PromptHistoryMessage: Sendable, Equatable {
    var role: PromptHistoryRole
    var content: String
}

/// Already-prepared, non-secret inputs for one prompt composition.
///
/// Stage 1 deliberately does not read mutable Conversation, Settings, Memory,
/// Soul or Skill state here. Stage 2 will supply this input from the run's
/// frozen/prepared execution context.
struct PromptCompositionInput: Sendable, Equatable {
    var modelID: ModelID
    var providerAdapterInstructions: String
    var history: [PromptHistoryMessage]
    var currentUserMessage: String
}

/// Pure prompt assembly. Owns no business state and performs no I/O.
struct PromptComposer: Sendable {

    static let runtimeSafetyBaseline = """
    Do not claim that an external action or result occurred unless it is present in the provided context.
    If a tool or external action fails, report the failure as it happened.
    """

    static let zenCore = """
    Answer the user's current request directly and clearly.
    Do not mechanically repeat background context.
    State uncertainty when needed.
    """

    func compose(_ input: PromptCompositionInput) -> ProviderChatRequest {
        let systemMessage = """
        Runtime / Safety
        \(Self.runtimeSafetyBaseline)

        Provider Adapter
        \(input.providerAdapterInstructions)

        Zen Core defaults
        \(Self.zenCore)
        """

        var messages: [ProviderChatMessage] = [
            ProviderChatMessage(
                role: .system,
                content: systemMessage
            )
        ]

        messages.append(
            contentsOf: input.history.map {
                ProviderChatMessage(
                    role: $0.role.providerRole,
                    content: $0.content
                )
            }
        )

        messages.append(
            ProviderChatMessage(
                role: .user,
                content: input.currentUserMessage
            )
        )

        return ProviderChatRequest(
            modelID: input.modelID,
            messages: messages
        )
    }
}
