/// Conversation 当前选择的执行目标：ProviderInstance 与 Model。
struct ConversationComposerConfiguration: Equatable, Sendable {
    var providerInstanceID: ProviderInstanceID
    var modelID: ModelID
}

enum ComposerSendAvailability: Equatable, Sendable {
    case unconfigured
    case checking
    case ready
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .unconfigured: return "尚未配置模型"
        case .checking: return "正在检查模型配置"
        case .ready: return nil
        case .unavailable(let message): return message
        }
    }
}
