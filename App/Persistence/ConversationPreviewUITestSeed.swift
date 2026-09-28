#if DEBUG
import Foundation
import GRDB

enum ConversationPreviewUITestSeed {
    static func makeStore() throws -> PersistenceStore {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            for index in 0..<12 {
                let date = Date(timeIntervalSince1970: Double(index))
                try ConversationRecord(id: "preview-ui-\(index)", title: "Workspace conversation \(index)",
                    createdAt: date, updatedAt: date, userActiveAt: date, pinned: false, lifecycle: .visible).insert(db)
            }
        }
        return store
    }
}
#endif
