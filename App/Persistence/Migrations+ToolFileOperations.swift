import GRDB

extension Migrations {
    static func registerV18(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18_tool_file_operations") { db in
            // Ordinary conversation deletion removes settled receipts. Unknown
            // effects keep only minimal proof alongside the existing tombstone;
            // no names, file contents or executable arguments survive here.
            try db.execute(sql: """
                CREATE TABLE toolFileOperation (
                    toolCallID TEXT COLLATE BINARY PRIMARY KEY NOT NULL,
                    attempt INTEGER NOT NULL CHECK(attempt >= 1),
                    intentBinding TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('create','modify','delete')),
                    assetID TEXT NOT NULL, versionID TEXT NOT NULL, fingerprint TEXT NOT NULL,
                    byteCount INTEGER NOT NULL CHECK(byteCount >= 0),
                    resultJSON TEXT NOT NULL
                );
                CREATE TRIGGER toolFileOperation_immutable BEFORE UPDATE ON toolFileOperation
                BEGIN SELECT RAISE(ABORT, 'Tool file receipt is immutable'); END;
                CREATE TRIGGER toolFileOperation_remove_settled_call AFTER DELETE ON toolCall
                WHEN OLD.state NOT IN ('dispatched','indeterminate')
                BEGIN DELETE FROM toolFileOperation WHERE toolCallID = OLD.id; END;
                """)
        }
    }
}
