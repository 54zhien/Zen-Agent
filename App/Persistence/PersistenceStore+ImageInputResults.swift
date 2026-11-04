import Foundation
import GRDB

extension PersistenceStore {
    /// Reads a completed result only for the named Run and exact message attachment version.
    func completedImageInputResult(
        runID: String,
        messageID: String,
        versionID: String
    ) throws -> ImageInputResultRecord? {
        try database.read { db in
            try ImageInputResultRecord
                .filter(Column("runID") == runID)
                .filter(Column("messageID") == messageID)
                .filter(Column("versionID") == versionID)
                .fetchOne(db)
        }
    }

    /// Stores a complete image-processing response before it is added to internal context.
    ///
    /// The source must be attached to the Run's trigger message. AgentStep and its
    /// attempts remain authoritative for a dispatched request whose outcome is unknown.
    func persistCompletedImageInputResult(_ result: ImageInputResultRecord) throws {
        do {
            try database.write { db in
                let sourceExists = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM agentRun
                        JOIN message ON message.id = agentRun.triggerMessageID
                        JOIN messageAttachment
                          ON messageAttachment.messageID = message.id
                         AND messageAttachment.versionID = ?
                        WHERE agentRun.id = ?
                          AND message.id = ?
                          AND message.conversationID = agentRun.conversationID
                    )
                    """, arguments: [result.versionID, result.runID, result.messageID]) ?? false
                guard sourceExists else {
                    throw PersistenceError.invalidTransition(
                        "image input result source is not attached to the Run trigger message"
                    )
                }

                var persistedResult = result
                persistedResult.targetEndpoint = ImageInputTargetProvenance.displayEndpoint(
                    from: result.targetEndpoint
                )
                try persistedResult.insert(db)
            }
        } catch let error as PersistenceError {
            throw error
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }
}
