/// Conversation 当前选择的执行目标：ProviderInstance 与 Model。
struct ConversationComposerConfiguration: Equatable, Sendable {
    var providerInstanceID: ProviderInstanceID
    var modelID: ModelID
}
