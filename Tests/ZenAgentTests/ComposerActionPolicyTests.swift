import Testing

@testable import ZenAgent

@Suite("Composer action policy")
struct ComposerActionPolicyTests {
    @Test("nativeCapabilityWithoutPipelineKeepsAttachmentClosed")
    func nativeCapabilityWithoutPipelineKeepsAttachmentClosed() {
        let pipeline = ComposerAttachmentPipelineStatus(
            imagePickerReady: false,
            filePickerReady: false,
            fileAssetIngestReady: false,
            messageAttachmentCommitReady: false,
            nativeImageEncodingReady: false,
            nativeFileEncodingReady: false,
            authorizedLocalImageRouteReady: false,
            authorizedLocalFileRouteReady: false
        )

        #expect(!ComposerActionPolicy.canAddImage(
            capabilities: Set([ModelCapability.vision]),
            pipeline: pipeline
        ))
        #expect(!ComposerActionPolicy.canAddFile(
            capabilities: Set([ModelCapability.files]),
            pipeline: pipeline
        ))
    }

    @Test("authorizedLocalRouteCanOpenMatchingAttachment")
    func authorizedLocalRouteCanOpenMatchingAttachment() {
        let imagePipeline = pipeline(
            imagePickerReady: true,
            filePickerReady: true,
            fileAssetIngestReady: true,
            messageAttachmentCommitReady: true,
            authorizedLocalImageRouteReady: true
        )
        #expect(ComposerActionPolicy.canAddImage(capabilities: [], pipeline: imagePipeline))
        #expect(!ComposerActionPolicy.canAddFile(
            capabilities: [.files],
            pipeline: imagePipeline
        ))

        let filePipeline = pipeline(
            imagePickerReady: true,
            filePickerReady: true,
            fileAssetIngestReady: true,
            messageAttachmentCommitReady: true,
            authorizedLocalFileRouteReady: true
        )
        #expect(ComposerActionPolicy.canAddFile(capabilities: [], pipeline: filePipeline))
        #expect(!ComposerActionPolicy.canAddImage(
            capabilities: [.vision],
            pipeline: filePipeline
        ))
    }

    @Test("pluginNeedsExecutableAuthorizedEffectiveCandidate")
    func pluginNeedsExecutableAuthorizedEffectiveCandidate() {
        let valid = ComposerPluginCandidate(
            id: "effective",
            runtimeAvailable: true,
            authorized: true,
            requestActivationImplemented: true
        )
        #expect(ComposerActionPolicy.canOpenPlugins([valid]))
        #expect(!ComposerActionPolicy.canOpenPlugins([
            ComposerPluginCandidate(
                id: "offline",
                runtimeAvailable: false,
                authorized: true,
                requestActivationImplemented: true
            )
        ]))
        #expect(!ComposerActionPolicy.canOpenPlugins([
            ComposerPluginCandidate(
                id: "unauthorized",
                runtimeAvailable: true,
                authorized: false,
                requestActivationImplemented: true
            )
        ]))
        #expect(!ComposerActionPolicy.canOpenPlugins([
            ComposerPluginCandidate(
                id: "ineffective",
                runtimeAvailable: true,
                authorized: true,
                requestActivationImplemented: false
            )
        ]))
        #expect(!ComposerActionPolicy.canOpenPlugins([]))
    }

    @Test("textRequiresEffectiveTextAndStreaming")
    func textRequiresEffectiveTextAndStreaming() {
        #expect(!ComposerActionPolicy.isSendable(
            draft: draft("  \n "),
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(!ComposerActionPolicy.isSendable(
            draft: draft("hello"),
            capabilities: [.text],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(!ComposerActionPolicy.isSendable(
            draft: draft("hello"),
            capabilities: [.streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(ComposerActionPolicy.isSendable(
            draft: draft("hello"),
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
    }

    @Test("unsupportedReferencesBlockSendEvenWithText")
    func unsupportedReferencesBlockSendEvenWithText() {
        let capabilities: Set<ModelCapability> = [.text, .streaming]
        let quoted = draft("hello", quote: QuoteReference(sourceID: "source", snapshot: "snapshot"))
        #expect(!ComposerActionPolicy.isSendable(
            draft: quoted,
            capabilities: capabilities,
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))

        let attached = draft("hello", attachments: [
            AttachmentReference(id: "image-1", displayName: "image.png", kind: .image),
        ])
        #expect(!ComposerActionPolicy.isSendable(
            draft: attached,
            capabilities: capabilities,
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
    }

    @Test("quoteOrAttachmentOnlyNeedsCommitPath")
    func quoteOrAttachmentOnlyNeedsCommitPath() {
        let quote = draft("", quote: QuoteReference(sourceID: "source", snapshot: "snapshot"))
        #expect(!ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false
        ))

        let file = draft("", attachments: [
            AttachmentReference(id: "file-1", displayName: "notes.txt", kind: .file),
        ])
        #expect(!ComposerActionPolicy.isSendable(
            draft: file,
            capabilities: [],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(ComposerActionPolicy.isSendable(
            draft: file,
            capabilities: [],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: true
        ))
    }

    private func pipeline(
        imagePickerReady: Bool = false,
        filePickerReady: Bool = false,
        fileAssetIngestReady: Bool = false,
        messageAttachmentCommitReady: Bool = false,
        nativeImageEncodingReady: Bool = false,
        nativeFileEncodingReady: Bool = false,
        authorizedLocalImageRouteReady: Bool = false,
        authorizedLocalFileRouteReady: Bool = false
    ) -> ComposerAttachmentPipelineStatus {
        ComposerAttachmentPipelineStatus(
            imagePickerReady: imagePickerReady,
            filePickerReady: filePickerReady,
            fileAssetIngestReady: fileAssetIngestReady,
            messageAttachmentCommitReady: messageAttachmentCommitReady,
            nativeImageEncodingReady: nativeImageEncodingReady,
            nativeFileEncodingReady: nativeFileEncodingReady,
            authorizedLocalImageRouteReady: authorizedLocalImageRouteReady,
            authorizedLocalFileRouteReady: authorizedLocalFileRouteReady
        )
    }

    private func draft(
        _ text: String,
        quote: QuoteReference? = nil,
        attachments: [AttachmentReference] = []
    ) -> ComposerDraftState {
        ComposerDraftState(
            text: text,
            selection: ComposerSelection(range: 0..<text.count),
            quoteReference: quote,
            attachments: attachments,
            presentationState: .resting
        )
    }
}
