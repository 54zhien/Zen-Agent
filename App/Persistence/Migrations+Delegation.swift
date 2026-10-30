import GRDB

extension Migrations {
    static func registerV27(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27_parent_delegation_runtime") { db in
            try db.create(table: "agentDelegationSettings") { t in
                t.primaryKey("id", .text)
                t.column("enabled", .boolean).notNull()
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "delegatedChildRun") { t in
                t.column("parentToolCallID", .text).notNull()
                    .references("toolCall", onDelete: .cascade)
                t.column("childRunID", .text).notNull()
                    .references("agentRun", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey("parentToolCallID")
                t.uniqueKey(["childRunID"])
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX agentRun_one_active_child_per_parent
                ON agentRun(parentRunID)
                WHERE kind = 'child' AND parentRunID IS NOT NULL
                  AND state NOT IN ('completed', 'failed', 'cancelled')
                """)
        }
    }
}
