import GRDB

enum ToolGrantInvalidationReason: String, Codable, Sendable {
    case policyTightened, subjectEnded, manualRevocation, legacyUnspecified
}

extension Migrations {
    static func registerV19(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19_tool_grant_invalidation_facts") { db in
            try db.execute(sql: """
                CREATE TABLE toolGrantInvalidation (
                    grantID TEXT COLLATE BINARY PRIMARY KEY NOT NULL REFERENCES toolScopedGrant(id) ON DELETE CASCADE,
                    reason TEXT NOT NULL CHECK(reason IN
                        ('policyTightened','subjectEnded','manualRevocation','legacyUnspecified'))
                );
                INSERT INTO toolGrantInvalidation(grantID, reason)
                SELECT id, 'legacyUnspecified' FROM toolScopedGrant WHERE validity = 'revoked';
                CREATE TRIGGER toolGrant_record_invalidation AFTER UPDATE OF validity ON toolScopedGrant
                WHEN OLD.validity = 'active' AND NEW.validity = 'revoked'
                BEGIN
                    INSERT INTO toolGrantInvalidation(grantID, reason)
                    VALUES (NEW.id, CASE
                        WHEN EXISTS (SELECT 1 FROM toolGlobalPolicy p
                            WHERE p.toolID = NEW.toolID AND p.actionID = NEW.actionID
                            AND p.revocationEpoch > NEW.revocationEpoch) THEN 'policyTightened'
                        WHEN NEW.subjectKind = 'parentConversation' AND NOT EXISTS
                            (SELECT 1 FROM conversation c WHERE c.id = NEW.subjectID AND c.lifecycle = 'visible')
                            THEN 'subjectEnded'
                        WHEN NEW.subjectKind = 'run' AND NOT EXISTS
                            (SELECT 1 FROM agentRun r WHERE r.id = NEW.subjectID
                             AND r.state NOT IN ('completed','failed','cancelled')) THEN 'subjectEnded'
                        ELSE 'manualRevocation' END)
                    ON CONFLICT(grantID) DO NOTHING;
                END;
                CREATE TRIGGER toolGrantInvalidation_immutable BEFORE UPDATE ON toolGrantInvalidation
                BEGIN SELECT RAISE(ABORT, 'Grant invalidation fact is immutable'); END;
                """)
        }
    }
}
