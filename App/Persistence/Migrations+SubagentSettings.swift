import GRDB

extension Migrations {
    static func registerV29(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29_subagent_model_target") { db in
            try db.alter(table: "agentDelegationSettings") { t in
                t.add(column: "explicitModelTarget", .text)
            }
        }
    }
}
