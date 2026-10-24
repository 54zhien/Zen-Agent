import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Stage8 Skill persistence")
struct SkillPersistenceTests {
    @Test("Skill versions and atomic Run selection have real durable tables")
    func schema() throws {
        let database = try ZenDatabase.inMemory()
        for name in ["skillRecord", "skillRevision", "runSkillSelection"] {
            #expect(try database.read { try $0.tableExists(name) })
        }
    }
    @Test("stored Skill instructions cannot be rewritten in place")
    func immutable() throws {
        let database = try ZenDatabase.inMemory()
        let exists = try database.read { try $0.tableExists("skillRevision") }
        try #require(exists)
        try database.write { db in
            try db.execute(sql: "INSERT INTO skillRecord(id,source,enabled,currentRevisionID,createdAt,updatedAt) VALUES('s','userCreated',0,'v1',1,1)")
            try db.execute(sql: "INSERT INTO skillRevision(id,skillID,definition,createdAt) VALUES('v1','s','{}',1)")
        }
        #expect(throws: DatabaseError.self) {
            try database.write { try $0.execute(sql: "UPDATE skillRevision SET definition = 'rewritten' WHERE id = 'v1'") }
        }
    }
}
