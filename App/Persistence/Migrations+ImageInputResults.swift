import GRDB

extension Migrations {
    static func registerV36(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v36_image_input_results") { db in
            try db.create(table: "imageInputResult") { t in
                t.column("runID", .text)
                    .notNull()
                    .references("agentRun", onDelete: .cascade)
                t.column("messageID", .text)
                    .notNull()
                    .references("message", onDelete: .cascade)
                t.column("versionID", .text)
                    .notNull()
                    .references("fileAssetVersion", onDelete: .restrict)
                t.column("internalContext", .text).notNull()
                t.column("targetProviderInstanceID", .text).notNull()
                t.column("targetAdapterID", .text).notNull()
                t.column("targetModelID", .text).notNull()
                t.column("targetEndpoint", .text).notNull()
                t.column("targetConfigRevision", .text).notNull()
                t.column("completedAt", .datetime).notNull()
                t.primaryKey(["runID", "messageID", "versionID"])
            }

            try db.create(
                index: "imageInputResult_by_message",
                on: "imageInputResult",
                columns: ["messageID"]
            )
            try db.create(
                index: "imageInputResult_by_version",
                on: "imageInputResult",
                columns: ["versionID"]
            )
        }
    }
}