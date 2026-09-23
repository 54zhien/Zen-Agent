import Foundation

enum ComposerPreviewTruncation: Equatable, Sendable {
    case tail
}

enum ComposerTextPresentation: Equatable, Sendable {
    case editor
    case preview(text: String, lineLimit: Int, truncation: ComposerPreviewTruncation)
}

enum ComposerTextProjection {
    static func presentation(for draft: ComposerDraftState) -> ComposerTextPresentation {
        switch draft.presentationState {
        case .editing:
            return .editor
        case .resting, .compact:
            return .preview(text: draft.text, lineLimit: 1, truncation: .tail)
        }
    }
}
