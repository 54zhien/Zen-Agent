import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer configuration")
struct ComposerConfigurationTests {
    @Test("conversationConfigurationStoresModelChoice")
    func conversationConfigurationStoresModelChoice() {
        let expectedModelID = ModelID(rawValue: "model-choice")
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: ProviderInstanceID(rawValue: "instance-choice"),
            modelID: expectedModelID
        )

        #expect(configuration.modelID == expectedModelID)
    }

    @Test("conversationConfigurationStoresProviderInstanceChoice")
    func conversationConfigurationStoresProviderInstanceChoice() {
        let expectedProviderInstanceID = ProviderInstanceID(rawValue: "instance-choice")
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: expectedProviderInstanceID,
            modelID: ModelID(rawValue: "model-choice")
        )

        #expect(configuration.providerInstanceID == expectedProviderInstanceID)
    }

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
