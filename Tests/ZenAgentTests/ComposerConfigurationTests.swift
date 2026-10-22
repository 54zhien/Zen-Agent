import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer configuration")
struct ComposerConfigurationTests {
    @Test("configurationIsIndependentFromDraftText")
    func configurationIsIndependentFromDraftText() {
        let expectedConfiguration = ConversationComposerConfiguration(
            providerInstanceID: ProviderInstanceID(rawValue: "instance-choice"),
            modelID: ModelID(rawValue: "model-choice")
        )
        let controller = ComposerController(configuration: expectedConfiguration)

        controller.draft.text = "new draft text"

        #expect(controller.configuration == expectedConfiguration)
    }
}
