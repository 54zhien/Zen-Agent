import GRDB

extension Migrations {
    static func registerV15(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15_tool_call_policy_admission") { db in
            try db.execute(sql: """
                ALTER TABLE toolCall ADD COLUMN failureReason TEXT
                CHECK (failureReason IS NULL OR failureReason IN
                    ('policyDenied','dependencyChanged','reapprovalNeeded','outcomeUnknown'))
                """)
            // No backfill: an old approved/prepared state is not proof of a
            // policy admission or a grant for the frozen intent it holds.
            try db.execute(sql: """
                CREATE TABLE toolCallPolicy (
                    toolCallID TEXT COLLATE BINARY PRIMARY KEY NOT NULL REFERENCES toolCall(id) ON DELETE CASCADE,
                    toolID TEXT COLLATE BINARY NOT NULL,
                    actionID TEXT COLLATE BINARY NOT NULL,
                    descriptorRevision TEXT NOT NULL,
                    mode TEXT NOT NULL CHECK (mode IN ('alwaysAllow','askEveryTime','deny')),
                    revocationEpoch INTEGER NOT NULL CHECK (typeof(revocationEpoch) = 'integer' AND revocationEpoch >= 0),
                    disposition TEXT NOT NULL CHECK (disposition IN ('allowed','needsApproval','denied')),
                    intentBinding TEXT NOT NULL
                )
                """)
        }
    }
}
