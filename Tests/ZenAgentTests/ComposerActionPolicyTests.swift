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
        let quoted = draft("hello", quote: makeQuote("snapshot"))
        #expect(!ComposerActionPolicy.isSendable(
            draft: quoted,
            capabilities: capabilities,
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))

        let attached = draft("hello", attachments: [
            AttachmentReference(
                id: "image-1",
                versionID: "version-1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))",
                displayName: "image.png",
                kind: .image
            ),
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
        let quote = draft("", quote: makeQuote("snapshot"))
        #expect(!ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false
        ))

        let file = draft("", attachments: [
            AttachmentReference(
                id: "file-1",
                versionID: "version-1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))",
                displayName: "notes.txt",
                kind: .file
            ),
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
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: true
        ))
    }

    @Test("quoteOnlyRequiresEffectiveTextAndStreaming")
    func quoteOnlyRequiresEffectiveTextAndStreaming() {
        let quote = draft("", quote: makeQuote("quoted passage"))
        let unsupportedCapabilities: [Set<ModelCapability>] = [[], [.text], [.streaming]]
        for capabilities in unsupportedCapabilities {
            #expect(!ComposerActionPolicy.isSendable(
                draft: quote,
                capabilities: capabilities,
                quoteCommitReady: true,
                imageInputReady: false,
                fileInputReady: false
            ))
        }
        #expect(!ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [.text, .streaming],
            quoteCommitReady: false,
            imageInputReady: false,
            fileInputReady: false
        ))
        #expect(ComposerActionPolicy.isSendable(
            draft: quote,
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false
        ))
    }

    @Test("attachmentEntriesStayClosedUnderThisPhaseRealState")
    func attachmentEntriesStayClosedUnderThisPhaseRealState() {
        let realPipeline = pipeline(
            fileAssetIngestReady: true,
            messageAttachmentCommitReady: true
        )

        #expect(realPipeline.fileAssetIngestReady)
        #expect(realPipeline.messageAttachmentCommitReady)
        #expect(!realPipeline.imagePickerReady)
        #expect(!realPipeline.filePickerReady)
        #expect(!realPipeline.nativeImageEncodingReady)
        #expect(!realPipeline.nativeFileEncodingReady)
        #expect(!realPipeline.authorizedLocalImageRouteReady)
        #expect(!realPipeline.authorizedLocalFileRouteReady)
        #expect(!ComposerActionPolicy.canAddImage(capabilities: [.vision], pipeline: realPipeline))
        #expect(!ComposerActionPolicy.canAddFile(capabilities: [.files], pipeline: realPipeline))
    }

    @Test("attachmentEntriesOpenOnlyWhenEveryGateIsReady")
    func attachmentEntriesOpenOnlyWhenEveryGateIsReady() {
        let imagePipeline = pipeline(
            imagePickerReady: true,
            fileAssetIngestReady: true,
            messageAttachmentCommitReady: true,
            nativeImageEncodingReady: true
        )
        #expect(ComposerActionPolicy.canAddImage(
            capabilities: [.vision],
            pipeline: imagePipeline
        ))
        #expect(!ComposerActionPolicy.canAddImage(
            capabilities: [.vision],
            pipeline: pipeline(
                imagePickerReady: true,
                fileAssetIngestReady: true,
                nativeImageEncodingReady: true
            )
        ))
        #expect(ComposerActionPolicy.canAddImage(
            capabilities: [],
            pipeline: pipeline(
                imagePickerReady: true,
                fileAssetIngestReady: true,
                messageAttachmentCommitReady: true,
                authorizedLocalImageRouteReady: true
            )
        ))

        let filePipeline = pipeline(
            filePickerReady: true,
            fileAssetIngestReady: true,
            messageAttachmentCommitReady: true,
            nativeFileEncodingReady: true
        )
        #expect(ComposerActionPolicy.canAddFile(
            capabilities: [.files],
            pipeline: filePipeline
        ))
        #expect(!ComposerActionPolicy.canAddFile(
            capabilities: [.files],
            pipeline: pipeline(
                filePickerReady: false,
                fileAssetIngestReady: true,
                messageAttachmentCommitReady: true,
                nativeFileEncodingReady: true
            )
        ))
        #expect(ComposerActionPolicy.canAddFile(
            capabilities: [],
            pipeline: pipeline(
                filePickerReady: true,
                fileAssetIngestReady: true,
                messageAttachmentCommitReady: true,
                authorizedLocalFileRouteReady: true
            )
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
            references: quote.map { [$0] } ?? [],
            attachments: attachments,
            presentationState: .resting
        )
    }

    private func makeQuote(_ snapshot: String) -> QuoteReference {
        QuoteReference(
            id: "policy-quote",
            source: QuoteSourceLocator(
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: "source-part",
                range: QuoteTextRange(utf16Start: 0, utf16Length: snapshot.utf16.count)
            ),
            snapshot: snapshot,
            createdAt: Fixtures.epoch
        )
    }
}
