import GRDB

extension Migrations {
    static func registerV22(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v22_environment") { db in
            try db.execute(sql: """
                CREATE TABLE environmentVariable (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope TEXT NOT NULL CHECK(scope = 'global' OR (scope LIKE 'skill:%' AND length(scope) > 6)),
                    key TEXT NOT NULL,
                    currentRevisionID TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','deleting')),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    UNIQUE(scope,key)
                );
                CREATE TABLE environmentRevision (
                    id TEXT PRIMARY KEY NOT NULL,
                    variableID TEXT NOT NULL REFERENCES environmentVariable(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN ('plain','secret')),
                    plainValue TEXT,
                    credentialReferenceID TEXT, credentialKind TEXT, credentialGeneration INTEGER,
                    createdAt DATETIME NOT NULL,
                    CHECK((kind = 'plain' AND plainValue IS NOT NULL AND credentialReferenceID IS NULL
                           AND credentialKind IS NULL AND credentialGeneration IS NULL)
                        OR (kind = 'secret' AND plainValue IS NULL AND credentialReferenceID IS NOT NULL
                            AND credentialKind IS NOT NULL AND credentialKind = 'environmentSecret'
                            AND credentialGeneration IS NOT NULL AND credentialGeneration > 0))
                );
                CREATE INDEX environmentRevision_by_variable ON environmentRevision(variableID);
                CREATE TRIGGER environmentRevision_reject_update BEFORE UPDATE ON environmentRevision
                BEGIN SELECT RAISE(ABORT, 'Environment revisions are immutable'); END;
                CREATE TRIGGER environmentVariable_identity_reject_update
                BEFORE UPDATE OF scope,key ON environmentVariable
                WHEN OLD.scope != NEW.scope OR OLD.key != NEW.key
                BEGIN SELECT RAISE(ABORT, 'Environment identity is immutable'); END;
                CREATE TABLE extensionCredentialRetirement (
                    referenceID TEXT NOT NULL, kind TEXT NOT NULL,
                    generation INTEGER NOT NULL, createdAt DATETIME NOT NULL,
                    PRIMARY KEY(referenceID,kind,generation)
                );
                """)
        }
    }
}
