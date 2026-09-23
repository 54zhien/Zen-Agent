import Foundation

struct ComposerAttachmentPipelineStatus: Equatable, Sendable {
    let imagePickerReady: Bool
    let filePickerReady: Bool
    let fileAssetIngestReady: Bool
    let messageAttachmentCommitReady: Bool
    let nativeImageEncodingReady: Bool
    let nativeFileEncodingReady: Bool
    let authorizedLocalImageRouteReady: Bool
    let authorizedLocalFileRouteReady: Bool
}

struct ComposerPluginCandidate: Equatable, Sendable {
    let id: String
    let runtimeAvailable: Bool
    let authorized: Bool
    let requestActivationImplemented: Bool
}

enum ComposerActionPolicy {
    static func canAddImage(
        capabilities: Set<ModelCapability>,
        pipeline: ComposerAttachmentPipelineStatus
    ) -> Bool {
        pipeline.imagePickerReady
            && pipeline.fileAssetIngestReady
            && pipeline.messageAttachmentCommitReady
            && ((capabilities.contains(.vision) && pipeline.nativeImageEncodingReady)
                || pipeline.authorizedLocalImageRouteReady)
    }

    static func canAddFile(
        capabilities: Set<ModelCapability>,
        pipeline: ComposerAttachmentPipelineStatus
    ) -> Bool {
        pipeline.filePickerReady
            && pipeline.fileAssetIngestReady
            && pipeline.messageAttachmentCommitReady
            && ((capabilities.contains(.files) && pipeline.nativeFileEncodingReady)
                || pipeline.authorizedLocalFileRouteReady)
    }

    static func canOpenPlugins(_ candidates: [ComposerPluginCandidate]) -> Bool {
        candidates.contains {
            $0.runtimeAvailable && $0.authorized && $0.requestActivationImplemented
        }
    }

    static func isSendable(
        draft: ComposerDraftState,
        capabilities: Set<ModelCapability>,
        quoteCommitReady: Bool,
        imageInputReady: Bool,
        fileInputReady: Bool
    ) -> Bool {
        let hasText = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText,
           !(capabilities.contains(.text) && capabilities.contains(.streaming)) {
            return false
        }

        if let quote = draft.quoteReference,
           quote.sourceID.isEmpty || quote.snapshot.isEmpty || !quoteCommitReady {
            return false
        }

        for attachment in draft.attachments {
            guard !attachment.id.isEmpty else { return false }
            switch attachment.kind {
            case .image:
                guard imageInputReady else { return false }
            case .file:
                guard fileInputReady else { return false }
            }
        }

        return hasText || draft.quoteReference != nil || !draft.attachments.isEmpty
    }
}
