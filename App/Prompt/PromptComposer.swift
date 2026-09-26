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
/// The Runtime supplies frozen sections for a real Run; this value never reads
/// mutable Conversation, Settings, Soul, Memory or Skill state itself.
struct PromptCompositionInput: Sendable, Equatable {
    var modelID: ModelID
    var providerAdapterInstructions: String
    var history: [PromptHistoryMessage]
    var currentUserMessage: String
    var currentUserQuotedSnapshots: [String] = []
    var soulInstructions: String? = nil
    var tools: [ProviderToolDefinition] = []
    var systemSections: PromptSystemSections = PromptTemplateCatalog.current
}

/// Pure prompt assembly. Owns no business state and performs no I/O.
struct PromptComposer: Sendable {

    func compose(_ input: PromptCompositionInput) -> ProviderChatRequest {
        var systemMessage = """
        Runtime / Safety
        \(input.systemSections.runtimeSafety)

        Provider Adapter
        \(input.providerAdapterInstructions)

        Zen Core defaults
        \(input.systemSections.zenCore)
        """
        if let soulInstructions = input.soulInstructions {
            systemMessage += "\n\nSoul style defaults\n\(soulInstructions)"
        }

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
