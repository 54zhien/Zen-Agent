import GRDB

extension Migrations {
    static func registerV30(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v30_authentication_recovery_evidence") { db in
            try db.execute(sql: """
                ALTER TABLE agentStep
                ADD COLUMN credentialFailureSource TEXT
                    CHECK(credentialFailureSource IS NULL OR credentialFailureSource IN (
                        'localFrozenCredentialRejected', 'providerHTTP401'
                    ))
                """)

            // SQLite cannot extend the CHECK attached to failureCode in-place.
            // Rebuild this leaf table while preserving its existing rows and FK.
            try db.execute(sql: """
                CREATE TABLE toolResult_v30 (
                    toolCallID TEXT PRIMARY KEY
                        REFERENCES toolCall(id) ON DELETE CASCADE,
                    payload TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'text'
                        CHECK(kind IN ('text','reference','error')),
                    failureCode TEXT
                        CHECK(failureCode IS NULL OR failureCode IN (
                            'executionFailed', 'resultTooLarge', 'invalidResult',
                            'redactionUnavailable', 'dependencyUnavailable',
                            'authenticationRequired', 'systemPermissionDenied',
                            'dependencyChanged', 'resourceInUse'
                        ))
                )
                """)
            try db.execute(sql: """
                INSERT INTO toolResult_v30(toolCallID, payload, createdAt, kind, failureCode)
                SELECT toolCallID, payload, createdAt, kind, failureCode
                FROM toolResult
                """)
            try db.execute(sql: "DROP TABLE toolResult")
            try db.execute(sql: "ALTER TABLE toolResult_v30 RENAME TO toolResult")
        }
    }

    static func registerV31(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v31_authentication_refresh_gate") { db in
            try db.alter(table: "agentStep") { t in
                t.add(column: "credentialFailureAt", .datetime)
            }
        }
    }
}
