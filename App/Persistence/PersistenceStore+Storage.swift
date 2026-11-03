import Foundation
import GRDB

private enum StorageMeasurementError: Error { case unreadableSize, overflow }

struct SettingsDatabaseFootprint: Sendable {
    let bytes: Int64?
    let searchIndexBytes: Int64?
    let conversations: Int
    let messages: Int
    let fileAssets: Int
    let snapshots: Int
}

extension PersistenceStore {
    func settingsDatabaseFootprint() throws -> SettingsDatabaseFootprint {
        let counts = try database.read { db in
            (try ConversationRecord.fetchCount(db), try MessageRecord.fetchCount(db),
             try FileAssetRecord.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentRun WHERE executionSnapshot IS NOT NULL") ?? 0)
        }
        func fileBytes(at path: String?) throws -> Int64? {
            guard let path else { return nil }
            var total: Int64 = 0
            for candidate in [path, path + "-wal", path + "-shm"] {
                if candidate != path, !FileManager.default.fileExists(atPath: candidate) { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate)
                guard let size = attributes[.size] as? NSNumber else { throw StorageMeasurementError.unreadableSize }
                let addition = total.addingReportingOverflow(size.int64Value)
                guard !addition.overflow else { throw StorageMeasurementError.overflow }
                total = addition.partialValue
            }
            return total
        }
        return SettingsDatabaseFootprint(
            bytes: try fileBytes(at: database.persistentPath),
            searchIndexBytes: try fileBytes(at: database.searchIndexPath),
            conversations: counts.0, messages: counts.1,
            fileAssets: counts.2, snapshots: counts.3)
    }
}
