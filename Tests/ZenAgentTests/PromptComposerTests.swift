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
                    .system(expectedSystem),
                    .user("Earlier user"),
                    .assistant(content: "Earlier assistant", reasoning: nil, toolCalls: []),
                    .user("Current user"),
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

        guard case .system(let firstSystem) = first.messages[0],
              case .system(let secondSystem) = second.messages[0]
        else {
            Issue.record("expected the composer to create system messages")
            return
        }
        #expect(firstSystem.contains("Adapter A"))
        #expect(!firstSystem.contains("Adapter B"))
        #expect(secondSystem.contains("Adapter B"))
        #expect(!secondSystem.contains("Adapter A"))
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
        guard case .system = request.messages[0] else {
            Issue.record("expected the first message to be structured as system")
            return
        }
        #expect(request.messages[1] == .user("Only current user"))
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

    @Test("quote snapshots stay in user context across the initial and continued request")
    func quoteSnapshotAppearsAsUserContextInInitialAndContinuedRequest() {
        let composer = PromptComposer()
        let snapshots = ["A quoted passage"]
        let initialText = "Explain this passage"
        let followUpText = "Continue with the same context"
        let initialUserContent = composer.userContent(
            text: initialText,
            quotedSnapshots: snapshots
        )
        let continuedUserContent = composer.userContent(
            text: followUpText,
            quotedSnapshots: snapshots
        )
        let initialInput = PromptCompositionInput(
            modelID: modelID,
            providerAdapterInstructions: "Adapter instructions",
            history: [],
            currentUserMessage: initialText,
            currentUserQuotedSnapshots: snapshots
        )
        let continuedInput = PromptCompositionInput(
            modelID: modelID,
            providerAdapterInstructions: "Adapter instructions",
            history: [
                PromptHistoryMessage(role: .user, content: initialUserContent),
                PromptHistoryMessage(role: .assistant, content: "A short answer"),
            ],
            currentUserMessage: followUpText,
            currentUserQuotedSnapshots: snapshots
        )

        let initialRequest = composer.compose(initialInput)
        let continuedRequest = composer.compose(continuedInput)

        #expect(initialUserContent.contains(snapshots[0]))
        #expect(initialInput.currentUserQuotedSnapshots == snapshots)
        #expect(initialRequest.messages.contains(.user(initialUserContent)))
        #expect(continuedRequest.messages.contains(.user(initialUserContent)))
        #expect(continuedRequest.messages.last == .user(continuedUserContent))
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
