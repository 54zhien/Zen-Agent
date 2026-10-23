import GRDB

extension Migrations {
    static func registerV16(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16_tool_system_consent") { db in
            // Replace the column constraint without rebuilding the owner table or
            // changing foreign-key/trigger identities. Retain every old diagnosis.
            try db.execute(sql: "ALTER TABLE toolCall RENAME COLUMN failureReason TO previousFailureReason")
            try db.execute(sql: """
                ALTER TABLE toolCall ADD COLUMN failureReason TEXT CHECK
                (failureReason IS NULL OR failureReason IN
                ('policyDenied','dependencyChanged','reapprovalNeeded','outcomeUnknown',
                 'systemPermissionDenied','dependencyUnavailable'))
                """)
            try db.execute(sql: "UPDATE toolCall SET failureReason = previousFailureReason")
            try db.execute(sql: "ALTER TABLE toolCall DROP COLUMN previousFailureReason")
            try db.execute(sql: """
                CREATE TABLE toolSystemConsent (
                    toolCallID TEXT COLLATE BINARY PRIMARY KEY NOT NULL REFERENCES toolCall(id) ON DELETE CASCADE,
                    attempt INTEGER NOT NULL CHECK(attempt >= 1),
                    intentBinding TEXT NOT NULL,
                    capabilityDescription TEXT NOT NULL,
                    phase TEXT NOT NULL CHECK(phase IN ('waiting','requesting','completed','declined')),
                    requestID TEXT,
                    requestOwner TEXT,
                    CHECK((requestID IS NULL) = (requestOwner IS NULL)),
                    CHECK(phase != 'requesting' OR requestID IS NOT NULL)
                )
                """)
        }
    }
}
