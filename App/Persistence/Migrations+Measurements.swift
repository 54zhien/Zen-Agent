import GRDB

extension Migrations {
    static func registerV28(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28_run_measurements") { db in
            try db.alter(table: "agentRun") { t in
                t.add(column: "stopRequestedAt", .datetime)
            }
            try db.alter(table: "agentStep") { t in
                t.add(column: "providerStartedAt", .datetime)
                t.add(column: "providerFinishedAt", .datetime)
                t.add(column: "reportedPromptTokens", .integer)
                t.add(column: "reportedCompletionTokens", .integer)
                t.add(column: "reportedTotalTokens", .integer)
            }
        }
    }
}
