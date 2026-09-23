import Foundation
import GRDB

extension PersistenceStore {

    func createFileAsset(
        _ asset: FileAssetRecord,
        initialVersion: FileAssetVersionRecord
    ) throws {
        guard initialVersion.assetID == asset.id,
              asset.currentVersionID == initialVersion.id
        else {
            throw PersistenceError.fileAssetVersionMismatch(
                assetID: asset.id,
                versionID: initialVersion.id
            )
        }

        do {
            try database.write { db in
                try asset.insert(db)
                try initialVersion.insert(db)
            }
        } catch let error as PersistenceError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }

    func advanceFileAsset(
        id assetID: String,
        to version: FileAssetVersionRecord,
        at now: Date = Date()
    ) throws {
        try database.write { db in
            guard try FileAssetRecord.fetchOne(db, key: assetID) != nil else {
                throw PersistenceError.fileAssetNotFound(assetID)
            }

            guard version.assetID == assetID else {
                throw PersistenceError.fileAssetVersionMismatch(
                    assetID: assetID,
                    versionID: version.id
                )
            }

            try version.insert(db)

            try db.execute(
                sql: """
                    UPDATE fileAsset
                    SET currentVersionID = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [version.id, now, assetID]
            )
        }
    }

    func fileAsset(id: String) throws -> FileAssetRecord? {
        try database.read { db in
            try FileAssetRecord.fetchOne(db, key: id)
        }
    }

    func fileAssetVersion(id: String) throws -> FileAssetVersionRecord? {
        try database.read { db in
            try FileAssetVersionRecord.fetchOne(db, key: id)
        }
    }

    func fileAssetVersionFingerprints() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT contentFingerprint FROM fileAssetVersion"))
        }
    }

    func attachments(forMessage messageID: String) throws -> [MessageAttachmentRecord] {
        try database.read { db in
            try MessageAttachmentRecord
                .filter(Column("messageID") == messageID)
                .order(Column("sequence"))
                .fetchAll(db)
        }
    }

    static func validateAttachment(
        _ attachment: MessageAttachmentRecord,
        in db: Database
    ) throws {
        guard try FileAssetRecord.fetchOne(db, key: attachment.assetID) != nil else {
            throw PersistenceError.fileAssetNotFound(attachment.assetID)
        }

        guard let version = try FileAssetVersionRecord.fetchOne(
            db,
            key: attachment.versionID
        ) else {
            throw PersistenceError.fileAssetVersionNotFound(attachment.versionID)
        }

        guard version.assetID == attachment.assetID else {
            throw PersistenceError.fileAssetVersionMismatch(
                assetID: attachment.assetID,
                versionID: attachment.versionID
            )
        }
    }
}
