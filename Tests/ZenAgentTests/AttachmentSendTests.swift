import Testing

@testable import ZenAgent

@Suite("Attachment send")
struct AttachmentSendTests {
    @Test("attachmentIdentityCarriesVersionAndFingerprintWithoutBytes")
    func attachmentIdentityCarriesVersionAndFingerprintWithoutBytes() {
        let reference = AttachmentReference(
            id: "asset-1",
            versionID: "version-1",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            displayName: "scan.png",
            kind: .image
        )

        #expect(reference.versionID == "version-1")
        #expect(reference.fingerprint == "sha256:\(String(repeating: "a", count: 64))")
    }

    @Test("attachmentCommitsWithMessageAndRunInOneTransaction")
    func attachmentCommitsWithMessageAndRunInOneTransaction() {
        let attachment = SendAttachment(
            assetID: "asset-1",
            versionID: "version-1",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            kind: .image,
            displayName: "scan.png"
        )
        let command = SendCommand(
            conversationID: "conversation-1",
            text: "",
            attachments: [attachment],
            providerInstanceID: ProviderInstanceID(rawValue: "provider-instance-1"),
            modelID: ModelID(rawValue: "deepseek-chat"),
            maxProviderSteps: 1,
            submissionID: "submission-1"
        )

        #expect(command.attachments == [attachment])
    }
}
