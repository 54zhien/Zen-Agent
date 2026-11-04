import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Image input result persistence")
struct ImageInputResultPersistenceTests {
    private func asset() -> FileAssetRecord {
        FileAssetRecord(
            id: "asset-image",
            displayName: "scan.png",
            currentVersionID: "version-image",
            origin: .conversation,
            createdAt: Fixtures.epoch,
            updatedAt: Fixtures.epoch
        )
    }

    private func version() -> FileAssetVersionRecord {
        FileAssetVersionRecord(
            id: "version-image",
            assetID: "asset-image",
            contentFingerprint: "sha256:image",
            byteCount: 12,
            mediaType: "image/png",
            createdAt: Fixtures.epoch
        )
    }

    private func attachment(messageID: String) -> MessageAttachmentRecord {
        MessageAttachmentRecord(
            id: "attachment-\(messageID)",
            messageID: messageID,
            assetID: "asset-image",
            versionID: "version-image",
            sequence: 0
        )
    }

    private func imageTarget() -> ImageInputTargetProvenance {
        ImageInputTargetProvenance(
            providerInstanceID: "image-provider",
            adapterID: "openai-responses",
            modelID: "gpt-4.1-mini",
            endpoint: "https://api.example.test/v1/responses",
            configRevision: "7"
        )
    }

    private func result(runID: String, messageID: String) -> ImageInputResultRecord {
        ImageInputResultRecord(
            runID: runID,
            messageID: messageID,
            versionID: "version-image",
            internalContext: "The image contains a red bicycle.",
            targetProvenance: imageTarget(),
            completedAt: Fixtures.epoch.addingTimeInterval(2)
        )
    }

    private func commit(
        conversationID: String = "c1",
        messageID: String,
        runID: String
    ) -> SendCommit {
        var commit = Fixtures.send(
            conversationID: conversationID,
            messageID: messageID,
            runID: runID
        )
        commit.attachments = [attachment(messageID: messageID)]
        return commit
    }

    @Test("a completed result survives reopen and is reusable only by its Run source")
    func completedResultSurvivesReopenAndIsRunScoped() throws {
        let url = try Fixtures.scratchPath(name: "image-input-results.sqlite")
        defer { Fixtures.cleanUp(url) }
        let persisted = result(runID: "run-image-1", messageID: "message-image-1")

        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try store.createFileAsset(asset(), initialVersion: version())
            try store.commitUserTurnAndCreateParentRun(commit(
                messageID: "message-image-1",
                runID: "run-image-1"
            ))
            try store.persistCompletedImageInputResult(persisted)

            #expect(try store.completedImageInputResult(
                runID: persisted.runID,
                messageID: persisted.messageID,
                versionID: persisted.versionID
            ) == persisted)

            try store.commitUserTurnAndCreateParentRun(commit(
                conversationID: "c2",
                messageID: "message-image-2",
                runID: "run-image-2"
            ))
            #expect(try store.completedImageInputResult(
                runID: "run-image-2",
                messageID: "message-image-2",
                versionID: persisted.versionID
            ) == nil)
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try reopened.completedImageInputResult(
            runID: persisted.runID,
            messageID: persisted.messageID,
            versionID: persisted.versionID
        ) == persisted)
    }

    @Test("pending deletion retains the result for undo and finalized deletion removes it")
    func resultFollowsConversationDeletionLifecycle() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createFileAsset(asset(), initialVersion: version())
        try store.commitUserTurnAndCreateParentRun(commit(
            messageID: "message-delete-image",
            runID: "run-delete-image"
        ))
        let persisted = result(runID: "run-delete-image", messageID: "message-delete-image")
        try store.persistCompletedImageInputResult(persisted)
        try store.finishRun(id: "run-delete-image", state: .cancelled, endReason: .cancelledByUser)

        try store.beginDeletion(conversationID: "c1")
        #expect(try store.completedImageInputResult(
            runID: persisted.runID,
            messageID: persisted.messageID,
            versionID: persisted.versionID
        ) == persisted)

        try store.undoDeletion(conversationID: "c1")
        #expect(try store.completedImageInputResult(
            runID: persisted.runID,
            messageID: persisted.messageID,
            versionID: persisted.versionID
        ) == persisted)

        try store.beginDeletion(conversationID: "c1")
        try store.finalizeDeletion(conversationID: "c1")
        #expect(try store.completedImageInputResult(
            runID: persisted.runID,
            messageID: persisted.messageID,
            versionID: persisted.versionID
        ) == nil)
        #expect(try store.fileAssetVersion(id: persisted.versionID) != nil)
    }

    @Test("image input result schema upgrades from v35")
    func v35AddsImageInputResultStorage() throws {
        let database = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(database, upTo: "v35_anthropic_workspace_id")
        #expect(try database.read { db in try db.tableExists("imageInputResult") } == false)

        try migrator.migrate(database)
        #expect(try database.read { db in try db.tableExists("imageInputResult") })
    }
}