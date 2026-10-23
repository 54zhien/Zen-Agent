import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Tool authorization upgrade")
struct ToolAuthorizationMigrationTests {
    @Test func v14PreparedCallDoesNotAcquireAuthorityOnUpgrade() throws {
        let url = try Fixtures.scratchPath(name: "tool-admission-v14.sqlite")
        defer { Fixtures.cleanUp(url) }
        var old = DatabaseMigrator()
        Migrations.registerV1(&old); Migrations.registerV2(&old); Migrations.registerV3(&old)
        Migrations.registerV4(&old); Migrations.registerV5(&old); Migrations.registerV6(&old)
        Migrations.registerV7(&old); Migrations.registerV8(&old); Migrations.registerV9(&old)
        Migrations.registerV10(&old); Migrations.registerV11(&old); Migrations.registerV12(&old)
        Migrations.registerV13(&old); Migrations.registerV14(&old)
        let commit = Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools)
        let original = "legacy frozen bytes"
        do {
            let database = try ZenDatabase.open(at: url.path(), migrator: old)
            let store = PersistenceStore(database: database)
            try store.commitUserTurnAndCreateParentRun(commit)
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO toolCall (id, agentRunID, action, state, executionIntent, attempt, createdAt, updatedAt)
                    VALUES ('old', 'r', 'tool', 'prepared', ?, 1, ?, ?)
                    """, arguments: [original, Fixtures.epoch, Fixtures.epoch])
            }
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let call = try #require(try store.toolCall(id: "old"))
        #expect(call.state == .prepared && call.executionIntent == original && call.attempt == 1)
        #expect(call.failureReason == nil)
        #expect(try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM toolCallPolicy") } == 0)
        #expect(try store.toolGrants(subject: .parentConversation("c")).isEmpty)
        #expect(try store.toolResult(toolCallID: "old") == nil)
    }
}
