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
}
