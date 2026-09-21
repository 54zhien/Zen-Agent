import Foundation
import Testing

@testable import ZenAgent

@Suite("Prompt composer")
struct PromptComposerTests {

    private let modelID = ModelID(rawValue: "prompt-model")

    private func input(
        providerAdapterInstructions: String = "Preserve the provider's plain-text chat semantics.",
        history: [PromptHistoryMessage] = [],
        currentUserMessage: String = "Current request"
    ) -> PromptCompositionInput {
        PromptCompositionInput(
            modelID: modelID,
            providerAdapterInstructions: providerAdapterInstructions,
            history: history,
            currentUserMessage: currentUserMessage
        )
    }

    @Test("composition has one trusted system message, ordered history, then the current user")
    func compositionOrderIsStable() {
        let request = PromptComposer().compose(
            input(
                history: [
                    PromptHistoryMessage(
                        role: .user,
                        content: "Earlier user"
                    ),
                    PromptHistoryMessage(
                        role: .assistant,
                        content: "Earlier assistant"
                    ),
                ],
                currentUserMessage: "Current user"
            )
        )

        let expectedSystem = """
        Runtime / Safety
        Do not claim that an external action or result occurred unless it is present in the provided context.
        If a tool or external action fails, report the failure as it happened.

        Provider Adapter
        Preserve the provider's plain-text chat semantics.

        Zen Core defaults
        Answer the user's current request directly and clearly.
        Do not mechanically repeat background context.
        State uncertainty when needed.
        """

        #expect(
            request == ProviderChatRequest(
                modelID: modelID,
                messages: [
                    ProviderChatMessage(
                        role: .system,
                        content: expectedSystem
                    ),
                    ProviderChatMessage(
                        role: .user,
                        content: "Earlier user"
                    ),
                    ProviderChatMessage(
                        role: .assistant,
                        content: "Earlier assistant"
                    ),
                    ProviderChatMessage(
                        role: .user,
                        content: "Current user"
                    ),
                ]
            )
        )
    }

    @Test("provider adapter instructions are explicit input rather than hidden composer state")
    func providerAdapterIsExplicitInput() {
        let composer = PromptComposer()

        let first = composer.compose(
            input(providerAdapterInstructions: "Adapter A")
        )
        let second = composer.compose(
            input(providerAdapterInstructions: "Adapter B")
        )

        #expect(first.messages[0].content.contains("Adapter A"))
        #expect(!first.messages[0].content.contains("Adapter B"))
        #expect(second.messages[0].content.contains("Adapter B"))
        #expect(!second.messages[0].content.contains("Adapter A"))
    }

    @Test("an empty history still leaves the current user after the system baseline")
    func emptyHistoryKeepsCurrentUserLast() {
        let request = PromptComposer().compose(
            input(
                history: [],
                currentUserMessage: "Only current user"
            )
        )

        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == .system)
        #expect(request.messages[1] == ProviderChatMessage(
            role: .user,
            content: "Only current user"
        ))
    }

    @Test("composition is deterministic for identical prepared input")
    func compositionIsDeterministic() {
        let prepared = input(
            history: [
                PromptHistoryMessage(
                    role: .user,
                    content: "Earlier"
                )
            ]
        )

        let composer = PromptComposer()

        #expect(composer.compose(prepared) == composer.compose(prepared))
    }

    @Test("prompt composition types remain Sendable")
    func promptTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}

        requireSendable(PromptHistoryRole.self)
        requireSendable(PromptHistoryMessage.self)
        requireSendable(PromptCompositionInput.self)
        requireSendable(PromptComposer.self)
    }
}
