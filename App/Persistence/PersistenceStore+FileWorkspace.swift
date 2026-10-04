import Foundation
import GRDB

extension PersistenceStore {
    func fileWorkspacePage(limit: Int = 50, after cursor: FileWorkspaceCursor? = nil) throws -> FileWorkspacePage {
        try database.read { db in try self.fileWorkspacePage(in: db, limit: limit, after: cursor) }
    }

    func fileWorkspacePageAsync(limit: Int = 50,
                               after cursor: FileWorkspaceCursor? = nil) async throws -> FileWorkspacePage {
        try await database.readAsync { db in try self.fileWorkspacePage(in: db, limit: limit, after: cursor) }
    }

    private func fileWorkspacePage(in db: Database, limit: Int,
                                   after cursor: FileWorkspaceCursor?) throws -> FileWorkspacePage {
        let count = min(50, max(1, limit))
        var predicate = "1 = 1"
        var arguments: StatementArguments = []
        if let cursor {
            predicate = "(a.updatedAt < ? OR (a.updatedAt = ? AND a.id > ?))"
            arguments += [cursor.updatedAt, cursor.updatedAt, cursor.id]
        }
        arguments += [count + 1]
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.displayName, a.currentVersionID, a.origin, a.updatedAt,
                   v.byteCount, v.mediaType, v.contentFingerprint
            FROM fileAsset a LEFT JOIN fileAssetVersion v
                ON v.id = a.currentVersionID AND v.assetID = a.id
            WHERE \(predicate) ORDER BY a.updatedAt DESC, a.id ASC LIMIT ?
            """, arguments: arguments)
        let items = rows.prefix(count).map { row -> FileWorkspaceItem in
            let id: String = row["id"]
            let origin: String = row["origin"]
            return FileWorkspaceItem(id: id, versionID: row["currentVersionID"],
                displayName: row["displayName"], byteCount: row["byteCount"], mediaType: row["mediaType"],
                fingerprint: row["contentFingerprint"], origin: FileAssetOrigin(rawValue: origin),
                cursor: FileWorkspaceCursor(updatedAt: row["updatedAt"], id: id))
        }
        return FileWorkspacePage(items: Array(items), nextCursor: rows.count > count ? items.last?.cursor : nil)
    }
}
