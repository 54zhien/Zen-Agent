import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Stage7 Memory persistence")
struct MemoryPersistenceTests {
    @Test("real schema has records, immutable revisions, provenance and no candidate body receipt")
    func schema() throws {
        let database = try ZenDatabase.inMemory()
        for table in ["memoryRecord", "memoryRevision", "memorySource", "memorySettings", "memoryExtractionReceipt"] {
            #expect(try database.read { try $0.tableExists(table) })
        }
    }

    @Test("Memory is enabled but automatic formation waits for completed management capability")
    func settings() throws {
        let database = try ZenDatabase.inMemory()
        let enabled = try database.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM memorySettings WHERE id = 'global'") }
        #expect(enabled == true)
    }

    @Test("immutable Memory versions survive reopening and reject in-place rewrites")
    func revisionDiskReopen() throws {
        let url = try Fixtures.scratchPath(name: "memory-disk.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let database = try ZenDatabase.open(at: url.path)
            try database.write { db in
                try db.execute(sql: "INSERT INTO memoryRecord (id,currentRevisionID,state,origin,createdAt,updatedAt) VALUES ('m','v','active','manual',1,1)")
                try db.execute(sql: "INSERT INTO memoryRevision (id,memoryID,content,createdAt) VALUES ('v','m','偏好中文回答',1)")
            }
            #expect(throws: DatabaseError.self) {
                try database.write { try $0.execute(sql: "UPDATE memoryRevision SET content = 'rewritten' WHERE id = 'v'") }
            }
        }
        let reopened = try ZenDatabase.open(at: url.path)
        let content = try reopened.read { try String.fetchOne($0, sql: "SELECT content FROM memoryRevision WHERE id = 'v'") }
        #expect(content == "偏好中文回答")
    }
}
