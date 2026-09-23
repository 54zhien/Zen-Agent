/// Composer 的呈现状态词汇表；各状态的布局由后续阶段实现。
enum ComposerPresentationState: Equatable, Sendable {
    case resting
    case editing
    case compact
}

/// Composer 的唯一 Draft 来源。
struct ComposerDraftState: Equatable, Sendable {
    var text: String
    var selection: ComposerSelection
    var references: [QuoteReference]
    var attachments: [AttachmentReference]
    var presentationState: ComposerPresentationState
}
