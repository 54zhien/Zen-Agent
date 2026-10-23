import GRDB

extension Migrations {
    static func registerV20(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v20_memory_management") { db in
            try db.execute(sql: """
                CREATE TABLE memorySettings (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = 'global'),
                    enabled BOOLEAN NOT NULL DEFAULT 1,
                    automaticEnabled BOOLEAN NOT NULL DEFAULT 0,
                    generation INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO memorySettings(id) VALUES ('global');
                CREATE TABLE memoryRecord (
                    id TEXT PRIMARY KEY NOT NULL,
                    currentRevisionID TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('active','archived')),
                    origin TEXT NOT NULL CHECK(origin IN ('manual','userEdited','explicitUser','automatic')),
                    factKey TEXT,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
                );
                CREATE TABLE memoryRevision (
                    id TEXT PRIMARY KEY NOT NULL,
                    memoryID TEXT NOT NULL REFERENCES memoryRecord(id) ON DELETE CASCADE,
                    content TEXT NOT NULL, createdAt DATETIME NOT NULL
                );
                CREATE INDEX memoryRevision_by_memory ON memoryRevision(memoryID);
                CREATE TRIGGER memoryRevision_reject_update BEFORE UPDATE ON memoryRevision
                BEGIN SELECT RAISE(ABORT, 'Memory revisions are immutable'); END;
                CREATE TABLE memorySource (
                    id TEXT PRIMARY KEY NOT NULL,
                    memoryID TEXT NOT NULL REFERENCES memoryRecord(id) ON DELETE CASCADE,
                    conversationID TEXT, messageID TEXT,
                    kind TEXT NOT NULL CHECK(kind IN ('manual','userEdited','explicitUser','automatic')),
                    missing BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL
                );
                CREATE INDEX memorySource_by_memory ON memorySource(memoryID);
                CREATE INDEX memorySource_by_conversation ON memorySource(conversationID);
                CREATE TABLE memoryExtractionReceipt (
                    messageID TEXT PRIMARY KEY NOT NULL,
                    createdAt DATETIME NOT NULL
                );
                """)
        }
    }
}
