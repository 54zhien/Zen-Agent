import Foundation
import Testing

@testable import ZenAgent

@Suite("File asset persistence")
struct FileAssetPersistenceTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func asset(
        id: String = "a1",
        currentVersionID: String = "v1"
    ) -> FileAssetRecord {
        FileAssetRecord(
            id: id,
            displayName: "notes.txt",
            currentVersionID: currentVersionID,
            origin: .imported,
            createdAt: Fixtures.epoch,
            updatedAt: Fixtures.epoch
        )
    }

    private func version(
        id: String = "v1",
        assetID: String = "a1",
        fingerprint: String = "sha256:one"
    ) -> FileAssetVersionRecord {
        FileAssetVersionRecord(
            id: id,
            assetID: assetID,
            contentFingerprint: fingerprint,
            byteCount: 3,
            mediaType: "text/plain",
            createdAt: Fixtures.epoch
        )
    }

    private func attachment(
        id: String = "att1",
        messageID: String = "m1",
        assetID: String = "a1",
        versionID: String = "v1",
        sequence: Int = 0
    ) -> MessageAttachmentRecord {
        MessageAttachmentRecord(
            id: id,
            messageID: messageID,
            assetID: assetID,
            versionID: versionID,
            sequence: sequence
        )
    }

    @Test("asset and version have separate stable identities")
    func assetAndVersionAreSeparateIdentities() throws {
        let store = try makeStore()
        try store.createFileAsset(asset(), initialVersion: version())

        let storedAsset = try store.fileAsset(id: "a1")
        let storedVersion = try store.fileAssetVersion(id: "v1")

        #expect(storedAsset?.id == "a1")
        #expect(storedAsset?.currentVersionID == "v1")
        #expect(storedVersion?.id == "v1")
        #expect(storedVersion?.assetID == "a1")
        #expect(storedVersion?.contentFingerprint == "sha256:one")
        #expect(storedAsset?.id != storedVersion?.id)
    }

    @Test("a message attachment stays pinned to version one")
    func attachmentPinsVersionOne() throws {
        let store = try makeStore()
        try store.createFileAsset(asset(), initialVersion: version())

        var commit = Fixtures.send(messageID: "m1", runID: "r1")
        commit.attachments = [attachment()]
        try store.commitUserTurnAndCreateParentRun(commit)

        try store.advanceFileAsset(
            id: "a1",
            to: version(id: "v2", fingerprint: "sha256:two"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )

        #expect(try store.fileAsset(id: "a1")?.currentVersionID == "v2")
        #expect(try store.attachments(forMessage: "m1")[0].versionID == "v1")
        #expect(try store.fileAssetVersion(id: "v1")?.contentFingerprint == "sha256:one")
    }

    @Test("conversation deletion removes the attachment but preserves shared asset data")
    func deletionPreservesAssetData() throws {
        let store = try makeStore()
        try store.createFileAsset(asset(), initialVersion: version())

        var commit = Fixtures.send(messageID: "m1", runID: "r1")
        commit.attachments = [attachment()]
        try store.commitUserTurnAndCreateParentRun(commit)

        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")

        #expect(try store.attachments(forMessage: "m1").isEmpty)
        #expect(try store.fileAsset(id: "a1") != nil)
        #expect(try store.fileAssetVersion(id: "v1") != nil)
    }

    @Test("an invalid attachment rolls back the message and run")
    func invalidAttachmentRollsBackSend() throws {
        let store = try makeStore()
        try store.createFileAsset(asset(), initialVersion: version())

        var commit = Fixtures.send(messageID: "m1", runID: "r1")
        commit.attachments = [attachment(versionID: "missing")]

        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(commit)
        } catch {
            failure = error
        }

        #expect(
            failure as? PersistenceError == .fileAssetVersionNotFound("missing")
        )
        #expect(try store.messages(inConversation: "c1").isEmpty)
        #expect(try store.run(id: "r1") == nil)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}

    @Test("file asset identities are Sendable")
    func identitiesAreSendable() {
        requireSendable(FileAssetOrigin.self)
        requireSendable(FileAssetRecord.self)
        requireSendable(FileAssetVersionRecord.self)
        requireSendable(MessageAttachmentRecord.self)
    }
}
