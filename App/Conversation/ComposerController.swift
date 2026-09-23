import Foundation
import Observation

/// Draft 的运行时所有者。
@Observable
final class ComposerController {
    var draft: ComposerDraftState
    var configuration: ConversationComposerConfiguration

    init(
        draft: ComposerDraftState = ComposerDraftState(
            text: "",
            selection: ComposerSelection(range: 0..<0),
            quoteReference: nil,
            attachments: [],
            presentationState: .resting
        ),
        configuration: ConversationComposerConfiguration
    ) {
        self.draft = draft
        self.configuration = configuration
    }
}
