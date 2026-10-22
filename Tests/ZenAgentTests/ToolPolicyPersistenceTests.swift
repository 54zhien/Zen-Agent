import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("S6-03 persistent global policy")
struct ToolPolicyPersistenceTests {
    @Test func defaultIsAskAndRoundTripsAcrossReopen() throws {
        let url = try Fixtures.scratchPath(name: "tool-policy.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            #expect(try store.toolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "v1").mode == .askEveryTime)
            let saved = try store.setToolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "v1", mode: .deny)
            #expect(saved.mode == .deny)
            #expect(saved.revocationEpoch == 1)
        }
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try reopened.toolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "v1").mode == .deny)
    }

    @Test func revisionAndTighteningAdvanceButWideningNeverLowersFloor() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        #expect(try store.setToolPolicy(toolID: "t", actionID: "a", descriptorRevision: "1", mode: .alwaysAllow).revocationEpoch == 0)
        #expect(try store.setToolPolicy(toolID: "t", actionID: "a", descriptorRevision: "1", mode: .askEveryTime).revocationEpoch == 1)
        #expect(try store.setToolPolicy(toolID: "t", actionID: "a", descriptorRevision: "1", mode: .deny).revocationEpoch == 2)
        #expect(try store.setToolPolicy(toolID: "t", actionID: "a", descriptorRevision: "1", mode: .alwaysAllow).revocationEpoch == 2)
        let changed = try store.setToolPolicy(toolID: "t", actionID: "a", descriptorRevision: "2", mode: .alwaysAllow)
        #expect(changed.revocationEpoch == 3)
        #expect(try store.toolPolicy(toolID: "t", actionID: "a", descriptorRevision: "1").descriptorRevision == "2")
    }

    @Test func firstRevisionUpdateRevokesGrantsIssuedUnderImplicitDefault() throws {
        let store = try GrantStorageFixture.store()
        let initial = try GrantStorageFixture.policy(store)
        try #require(try store.issueToolGrant(id: "default-grant", grant: GrantStorageFixture.grant(), expectedPolicy: initial))

        let changed = try store.setToolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "r2", mode: .askEveryTime)

        #expect(changed.revocationEpoch == 1)
        #expect(try store.toolGrant(id: "default-grant")?.validity == .revoked)
    }

    @Test func opaqueKeysDoNotCanonicalizeUnicode() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.setToolPolicy(toolID: "caf\u{e9}", actionID: "read", descriptorRevision: "v1", mode: .deny)
        #expect(try store.toolPolicy(toolID: "caf\u{e9}", actionID: "read", descriptorRevision: "v1").mode == .deny)
        #expect(try store.toolPolicy(toolID: "cafe\u{301}", actionID: "read", descriptorRevision: "v1").mode == .askEveryTime)
        #expect(try store.toolPolicy(toolID: "caf\u{e9}", actionID: "write", descriptorRevision: "v1").mode == .askEveryTime)
    }

    @Test func migrationPreservesExistingBodyAndDoesNotInventGrants() throws {
        let url = try Fixtures.scratchPath(name: "tool-policy-v13.sqlite")
        defer { Fixtures.cleanUp(url) }
        var old = DatabaseMigrator()
        Migrations.registerV1(&old); Migrations.registerV2(&old); Migrations.registerV3(&old)
        Migrations.registerV4(&old); Migrations.registerV5(&old); Migrations.registerV6(&old)
        Migrations.registerV7(&old); Migrations.registerV8(&old); Migrations.registerV9(&old)
        Migrations.registerV10(&old); Migrations.registerV11(&old); Migrations.registerV12(&old); Migrations.registerV13(&old)
        do {
            let db = try ZenDatabase.open(at: url.path(), migrator: old)
            try db.write { db in
                try Fixtures.conversation().insert(db)
                try Fixtures.message(id: "legacy-message").insert(db)
                try Fixtures.textPart(id: "legacy-part", messageID: "legacy-message").insert(db)
            }
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try store.text(ofPart: "legacy-part") == "hello")
        #expect(try store.toolGrants(subject: .parentConversation("c1")).isEmpty)
        #expect(try store.database.read { try $0.tableExists("toolGlobalPolicy") })
        #expect(try store.database.read { try $0.tableExists("toolScopedGrant") })
    }
}
