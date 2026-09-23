import Foundation

enum PromptHistoryRole: Sendable, Equatable {
    case user
    case assistant
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
    var currentUserQuotedSnapshots: [String] = []
    var tools: [ProviderToolDefinition] = []
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
            .system(systemMessage)
        ]

        messages.append(
            contentsOf: input.history.map {
                switch $0.role {
                case .user:
                    return .user($0.content)
                case .assistant:
                    return .assistant(
                        content: $0.content,
                        reasoning: nil,
                        toolCalls: []
                    )
                }
            }
        )

        messages.append(.user(userContent(
            text: input.currentUserMessage,
            quotedSnapshots: input.currentUserQuotedSnapshots
        )))

        return ProviderChatRequest(
            modelID: input.modelID,
            messages: messages,
            tools: input.tools
        )
    }

    func userContent(text: String, quotedSnapshots: [String]) -> String {
        guard !quotedSnapshots.isEmpty else { return text }

        let quotedContext = quotedSnapshots.enumerated().map { index, snapshot in
            "Quoted passage \(index + 1):\n\(snapshot)"
        }.joined(separator: "\n\n")
        let parts = [text, "Quoted context:\n\(quotedContext)"].filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n")
    }
}
