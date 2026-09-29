import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Manual title migration")
struct ConversationMetadataMigrationTests {
    @Test("v11 history upgrades without changing body, metadata or activity")
    func upgradesExistingV11() throws {
        let url = try Fixtures.scratchPath(name: "manual-title-v11.sqlite")
        defer { Fixtures.cleanUp(url) }
        var old = DatabaseMigrator()
        Migrations.registerV1(&old)
        Migrations.registerV2(&old)
        Migrations.registerV3(&old)
        Migrations.registerV4(&old)
        Migrations.registerV5(&old)
        Migrations.registerV6(&old)
        Migrations.registerV7(&old)
        Migrations.registerV8(&old)
        Migrations.registerV9(&old)
        Migrations.registerV10(&old)
        Migrations.registerV11(&old)

        do {
            let before = PersistenceStore(database: try ZenDatabase.open(at: url.path(), migrator: old))
            try before.database.write { db in
                try Fixtures.conversation().insert(db)
                try Fixtures.message(id: "old-message").insert(db)
                try Fixtures.textPart(id: "old-part", messageID: "old-message").insert(db)
            }
        }
        let after = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try after.hasManualConversationTitle(id: "c1") == false)
        #expect(try after.conversation(id: "c1")?.title == "A conversation")
        #expect(try after.conversation(id: "c1")?.userActiveAt == Fixtures.epoch)
        #expect(try after.messages(inConversation: "c1").map(\.id) == ["old-message"])
        #expect(try after.text(ofPart: "old-part") != nil)
        try after.renameConversation(id: "c1", title: "migrated manual", at: Fixtures.epoch)
        #expect(try after.hasManualConversationTitle(id: "c1"))
    }
}
