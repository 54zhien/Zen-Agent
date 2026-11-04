import GRDB

extension Migrations {
    static func registerV37(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v37_image_input_attempt") { db in
            try db.alter(table: "agentRun") { table in
                table.add(column: "imageInputSeed", .text)
            }
            try db.alter(table: "agentStep") { table in
                table.add(column: "purpose", .text)
                    .notNull()
                    .defaults(to: AgentStepPurpose.modelResponse.rawValue)
            }
        }
    }
}
