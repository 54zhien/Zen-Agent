import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Stage7 Memory persistence")
struct MemoryPersistenceTests {
    @Test("real v19 disk upgrade preserves Conversation and adds Memory without a reset")
    func migration() throws {
        let url = try Fixtures.scratchPath(name: "memory-v19.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Migrations.makeMigrator().migrate(queue, upTo: "v19_tool_grant_invalidation_facts")
            try queue.write { try Fixtures.conversation(id: "before-memory").insert($0) }
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        #expect(try store.conversation(id: "before-memory") != nil)
        #expect(try store.database.read { try $0.tableExists("memoryRecord") })
    }

#if os(iOS)
    @Test("actual database open requests the chosen native protection for SQLite and sidecars")
    func fileProtection() throws {
        let url = try Fixtures.scratchPath(name: "memory-protection.sqlite")
        defer { Fixtures.cleanUp(url) }
        let files = MemoryProtectionFileManager()
        let database = try ZenDatabase.open(at: url.path, fileManager: files)
        _ = try database.read { try $0.tableExists("memoryRecord") }
        #expect(!files.requests.isEmpty)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            #expect(files.requests[path] == .completeUntilFirstUserAuthentication)
#if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
#endif
        }
    }
#endif

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

#if os(iOS)
private final class MemoryProtectionFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [String: FileProtectionType] = [:]
    var requests: [String: FileProtectionType] { lock.withLock { requested } }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            lock.withLock { requested[path] = protection }
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
#endif
