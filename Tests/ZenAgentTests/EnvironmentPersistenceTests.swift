import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Stage8 Environment persistence")
struct EnvironmentPersistenceTests {
    @Test("real v21 disk upgrade preserves the existing Conversation and adds environment storage")
    func migration() throws {
        let url = try Fixtures.scratchPath(name: "environment-upgrade.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Migrations.makeMigrator().migrate(queue, upTo: "v21_memory_formation")
            try queue.write { try Fixtures.conversation(id: "before-environment").insert($0) }
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        #expect(try store.conversation(id: "before-environment") != nil)
        #expect(try store.database.read { try $0.tableExists("environmentVariable") })
        #expect(try store.database.read { try $0.tableExists("environmentRevision") })
    }

    @Test("historical plain revisions survive disk reopening and reject in-place rewrites")
    func immutableRevision() throws {
        let url = try Fixtures.scratchPath(name: "environment-revisions.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let database = try ZenDatabase.open(at: url.path)
            let exists = try database.read { try $0.tableExists("environmentRevision") }
            try #require(exists)
            try database.write { db in
                try db.execute(sql: "INSERT INTO environmentVariable (id,scope,key,currentRevisionID,createdAt,updatedAt) VALUES ('e','global','LANGUAGE','v1',1,1)")
                try db.execute(sql: "INSERT INTO environmentRevision (id,variableID,kind,plainValue,createdAt) VALUES ('v1','e','plain','Chinese',1)")
            }
            #expect(throws: DatabaseError.self) {
                try database.write { try $0.execute(sql: "UPDATE environmentRevision SET plainValue = 'rewritten' WHERE id = 'v1'") }
            }
        }
        let reopened = try ZenDatabase.open(at: url.path)
        let value = try reopened.read { try String.fetchOne($0, sql: "SELECT plainValue FROM environmentRevision WHERE id = 'v1'") }
        #expect(value == "Chinese")
    }

    @Test("a secret revision cannot simultaneously persist a plain value")
    func secretStorageConstraint() throws {
        let database = try ZenDatabase.inMemory()
        let exists = try database.read { try $0.tableExists("environmentRevision") }
        try #require(exists)
        try database.write { try $0.execute(sql: "INSERT INTO environmentVariable (id,scope,key,currentRevisionID,createdAt,updatedAt) VALUES ('e','global','TOKEN','v1',1,1)") }
        #expect(throws: DatabaseError.self) {
            try database.write { try $0.execute(sql: "INSERT INTO environmentRevision (id,variableID,kind,plainValue,credentialReferenceID,credentialGeneration,createdAt) VALUES ('v1','e','secret','must-not-persist','opaque',1,1)") }
        }
    }
}
