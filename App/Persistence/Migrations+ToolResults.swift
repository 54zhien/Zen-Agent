import GRDB

extension Migrations {
    static func registerV17(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17_tool_result_guard") { db in
            try db.execute(sql: "ALTER TABLE toolResult ADD COLUMN kind TEXT NOT NULL DEFAULT 'text' CHECK(kind IN ('text','reference','error'))")
            try db.execute(sql: "ALTER TABLE toolResult ADD COLUMN failureCode TEXT CHECK(failureCode IS NULL OR failureCode IN ('executionFailed','resultTooLarge','invalidResult','redactionUnavailable','dependencyUnavailable'))")
        }
    }
}
