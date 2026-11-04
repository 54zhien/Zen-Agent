import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import ZenAgent

@Suite("Composer image attachments")
@MainActor
struct ComposerImageAttachmentTests {
    @Test("selected image becomes a managed version with a readable thumbnail")
    func selectedImageBecomesManagedAsset() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let service = ManagedImageAttachmentService(files: files, store: store)
        let bytes = try imageData(color: .systemRed)

        let attachment = try await service.importImage(
            data: bytes,
            displayName: "selected.png",
            mediaType: UTType.png.identifier
        )

        let asset = try #require(try store.fileAsset(id: attachment.id))
        let version = try #require(try store.fileAssetVersion(id: attachment.versionID))
        #expect(attachment.kind == .image)
        #expect(asset.currentVersionID == attachment.versionID)
        #expect(version.assetID == asset.id)
        #expect(version.contentFingerprint == ManagedFileStore.fingerprint(of: bytes))
        #expect(try files.loadVerifiedBlob(for: sendAttachment(attachment), in: store) == bytes)
        #expect(try await service.thumbnailData(for: attachment) != nil)
    }

    @Test("draft image removal preserves the selected asset version boundary")
    func draftImageCanBeRemoved() {
        let attachment = AttachmentReference(
            id: "asset-1",
            versionID: "version-1",
            fingerprint: "sha256:fixture",
            displayName: "photo.png",
            kind: .image
        )
        let controller = ComposerController(configuration: nil)

        controller.addImageAttachment(attachment)
        #expect(controller.draft.attachments == [attachment])

        controller.removeImageAttachment(attachment)
        #expect(controller.draft.attachments.isEmpty)
    }

    @Test("timeline reads the version attached to the user message")
    func timelineKeepsMessageAttachmentVersion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let service = ManagedImageAttachmentService(files: files, store: store)
        let originalBytes = try imageData(color: .systemRed)
        let attachment = try await service.importImage(
            data: originalBytes,
            displayName: "photo.png",
            mediaType: UTType.png.identifier
        )
        var commit = Fixtures.send(messageID: "image-message", runID: "image-run")
        commit.attachments = [MessageAttachmentRecord(
            id: "image-message-attachment",
            messageID: "image-message",
            assetID: attachment.id,
            versionID: attachment.versionID,
            sequence: 0
        )]
        try store.commitUserTurnAndCreateParentRun(commit)

        let newerBytes = try imageData(color: .systemBlue)
        let newerVersionID = "newer-version"
        try store.advanceFileAsset(id: attachment.id, to: FileAssetVersionRecord(
            id: newerVersionID,
            assetID: attachment.id,
            contentFingerprint: ManagedFileStore.fingerprint(of: newerBytes),
            byteCount: Int64(newerBytes.count),
            mediaType: UTType.png.identifier,
            createdAt: Fixtures.epoch.addingTimeInterval(1)
        ))

        let projection = try ConversationTimelineLoader.load(conversationID: "c1", from: store)
        let turn = try #require(projection.turns.first)
        let imageItem = try #require(turn.items.first { item in
            if case .imageAttachments = item { return true }
            return false
        })
        guard case .imageAttachments(let images) = imageItem else {
            Issue.record("The user turn should contain its image attachment.")
            return
        }

        #expect(images.map(\.id) == ["image-message-attachment"])
        #expect(images.map(\.attachment.versionID) == [attachment.versionID])
        #expect(try store.fileAsset(id: attachment.id)?.currentVersionID == newerVersionID)
        #expect(try files.loadVerifiedBlob(for: sendAttachment(attachment), in: store) == originalBytes)
    }

    private func imageData(color: UIColor) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return try #require(renderer.image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    private func sendAttachment(_ attachment: AttachmentReference) -> SendAttachment {
        SendAttachment(
            assetID: attachment.id,
            versionID: attachment.versionID,
            fingerprint: attachment.fingerprint,
            kind: attachment.kind,
            displayName: attachment.displayName
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
