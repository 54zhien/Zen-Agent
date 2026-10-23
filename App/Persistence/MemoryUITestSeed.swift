#if DEBUG
import Foundation
import GRDB

extension PersistenceStore {
    func seedMemoryForUITest() throws {
        try database.write { db in
            let now = Date()
            try MemoryRecord(id: "fixture-memory", currentRevisionID: "fixture-memory-v1", state: "active",
                origin: .automatic, factKey: "environment.os", createdAt: now, updatedAt: now).insert(db)
            try MemoryRevisionRecord(id: "fixture-memory-v1", memoryID: "fixture-memory", content: "I work on Windows", createdAt: now).insert(db)
            try MemorySourceRecord(id: "fixture-memory-source", memoryID: "fixture-memory", conversationID: "deleted-memory-source",
                messageID: nil, kind: .automatic, missing: true, createdAt: now).insert(db)
        }
    }
}
#endif
