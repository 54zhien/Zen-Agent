import GRDB

struct StoredToolGrantSettings: Sendable {
    let id: String
    let grant: ToolScopedGrant
    let invalidation: ToolGrantInvalidationReason?
}

extension PersistenceStore {
    func toolGrantsForSettings() throws -> [StoredToolGrantSettings] {
        try database.read { db in
            try ToolGrantRecord.order(Column("id")).fetchAll(db).map { record in
                let value = try String.fetchOne(db, sql: "SELECT reason FROM toolGrantInvalidation WHERE grantID = ?",
                                                arguments: [record.id])
                return StoredToolGrantSettings(id: record.id, grant: try record.snapshot(),
                    invalidation: value.flatMap(ToolGrantInvalidationReason.init(rawValue:)))
            }
        }
    }
}
