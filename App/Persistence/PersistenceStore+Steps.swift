import Foundation
import GRDB

/// Per-request identity, and the check that discards stale streaming events.
///
/// **Not an Agent Runtime.** There is no loop, no state machine and no retry policy
/// here. What is here is the storage side of one question: when an event arrives
/// claiming to belong to a particular provider request, is that request still the one
/// we are listening to?
///
/// The rule that makes it answerable is that **a replay is a new attempt, never a
/// continuation of the old one.** A stopped run's late delta and a live one are
/// indistinguishable by content, so identity is the only thing that separates them.
extension PersistenceStore {

    /// Records a provider request for a step.
    ///
    /// `attempt` increments per real request, including replays. The composite primary
    /// key rejects recording the same attempt twice, so a double-recorded request
    /// fails loudly instead of quietly becoming two attempts — which would make the
    /// identity check below answer the wrong question.
    func recordStep(_ step: AgentStepRecord) throws {
        try database.write { db in
            try step.insert(db)
        }
    }

    func recordProtocolResponse(_ response: String, for step: AgentStepRecord) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE agentStep
                    SET protocolResponse = ?
                    WHERE stepID = ? AND runID = ? AND sequence = ? AND attempt = ?
                        AND protocolResponse IS NULL
                    """,
                arguments: [response, step.stepID, step.runID, step.sequence, step.attempt]
            )
            guard db.changesCount == 1 else {
                throw PersistenceError.invalidTransition("provider response did not match one empty step attempt")
            }
        }
    }

    func markProviderStepStarted(_ identity: AttemptIdentity, at now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE agentStep SET providerStartedAt = COALESCE(providerStartedAt, ?)
                WHERE stepID = ? AND attempt = ?
                """, arguments: [now, identity.stepID, identity.attempt])
        }
    }

    /// Crosses the Image Input dispatch boundary only while this Run still owns the
    /// requesting phase and the named image attempt is current.
    func markImageInputStepStarted(
        runID: String,
        identity: AttemptIdentity,
        at now: Date = Date()
    ) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE agentStep
                SET providerStartedAt = COALESCE(providerStartedAt, ?)
                WHERE stepID = ? AND runID = ? AND attempt = ? AND purpose = ?
                  AND EXISTS (
                    SELECT 1 FROM agentRun
                    WHERE agentRun.id = agentStep.runID
                      AND agentRun.state = ? AND agentRun.stopRequestedAt IS NULL
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM agentStep newer
                    WHERE newer.stepID = agentStep.stepID AND newer.attempt > agentStep.attempt
                  )
                """, arguments: [
                    now, identity.stepID, runID, identity.attempt,
                    AgentStepPurpose.imageInput.rawValue, RunState.requestingModel.rawValue
                ])
            return db.changesCount == 1
        }
    }

    /// The stop check, completed result, and attempt completion share one write
    /// transaction. A response arriving after Stop therefore cannot become context.
    func completeImageInput(
        _ result: ImageInputResultRecord,
        runID: String,
        identity: AttemptIdentity,
        at now: Date = Date()
    ) throws -> Bool {
        do {
            return try database.write { db in
                let current = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM agentStep
                        JOIN agentRun ON agentRun.id = agentStep.runID
                        WHERE agentStep.stepID = ? AND agentStep.runID = ?
                          AND agentStep.attempt = ? AND agentStep.purpose = ?
                          AND agentStep.providerStartedAt IS NOT NULL
                          AND agentStep.providerFinishedAt IS NULL
                          AND agentRun.state = ? AND agentRun.stopRequestedAt IS NULL
                          AND NOT EXISTS (
                            SELECT 1 FROM agentStep newer
                            WHERE newer.stepID = agentStep.stepID
                              AND newer.attempt > agentStep.attempt
                          )
                    )
                    """, arguments: [
                        identity.stepID, runID, identity.attempt,
                        AgentStepPurpose.imageInput.rawValue, RunState.requestingModel.rawValue
                    ]) ?? false
                guard current else { return false }

                let sourceExists = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM agentRun
                        JOIN message ON message.id = agentRun.triggerMessageID
                        JOIN messageAttachment
                          ON messageAttachment.messageID = message.id
                         AND messageAttachment.versionID = ?
                        WHERE agentRun.id = ? AND message.id = ?
                          AND message.conversationID = agentRun.conversationID
                    )
                    """, arguments: [result.versionID, result.runID, result.messageID]) ?? false
                guard sourceExists, result.runID == runID else {
                    throw PersistenceError.invalidTransition(
                        "image input result source is not attached to the Run trigger message"
                    )
                }

                var persistedResult = result
                persistedResult.targetEndpoint = ImageInputTargetProvenance.displayEndpoint(
                    from: result.targetEndpoint
                )
                try persistedResult.insert(db)
                try db.execute(sql: """
                    UPDATE agentStep SET providerFinishedAt = COALESCE(providerFinishedAt, ?)
                    WHERE stepID = ? AND runID = ? AND attempt = ? AND purpose = ?
                      AND providerStartedAt IS NOT NULL AND providerFinishedAt IS NULL
                    """, arguments: [
                        now, identity.stepID, runID, identity.attempt,
                        AgentStepPurpose.imageInput.rawValue
                    ])
                guard db.changesCount == 1 else {
                    throw PersistenceError.invalidTransition(
                        "image input completion did not match one started attempt"
                    )
                }
                return true
            }
        } catch let error as PersistenceError {
            throw error
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw PersistenceError.constraintViolation
        }
    }

    func recordProviderUsage(_ usage: ProviderTokenUsage, for identity: AttemptIdentity) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE agentStep
                SET reportedPromptTokens = ?, reportedCompletionTokens = ?, reportedTotalTokens = ?
                WHERE stepID = ? AND attempt = ?
                """, arguments: [
                    usage.promptTokens,
                    usage.completionTokens,
                    usage.totalTokens,
                    identity.stepID,
                    identity.attempt,
                ])
        }
    }

    func markProviderStepFinished(_ identity: AttemptIdentity, at now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE agentStep SET providerFinishedAt = COALESCE(providerFinishedAt, ?)
                WHERE stepID = ? AND attempt = ?
                """, arguments: [now, identity.stepID, identity.attempt])
        }
    }

    func steps(inRun runID: String) throws -> [AgentStepRecord] {
        try database.read { db in
            try AgentStepRecord
                .filter(Column("runID") == runID)
                .order(Column("sequence"), Column("attempt"))
                .fetchAll(db)
        }
    }

    func steps(inRun runID: String, purpose: AgentStepPurpose) throws -> [AgentStepRecord] {
        try database.read { db in
            try AgentStepRecord
                .filter(Column("runID") == runID)
                .filter(Column("purpose") == purpose.rawValue)
                .order(Column("sequence"), Column("attempt"))
                .fetchAll(db)
        }
    }

    /// The attempt currently being listened to for a step, if any.
    func currentAttempt(ofStep stepID: String) throws -> AgentStepRecord? {
        try database.read { db in
            try AgentStepRecord
                .filter(Column("stepID") == stepID)
                .order(Column("attempt").desc)
                .fetchOne(db)
        }
    }

    /// Whether an arriving event belongs to the attempt we are still listening to.
    ///
    /// This is the whole point of recording attempts. A provider stream that was
    /// stopped, or a run that recovered onto a new attempt, keeps delivering events for
    /// a while — and those events are indistinguishable from live ones except by the
    /// identity they carry.
    func accepts(_ identity: AttemptIdentity) throws -> Bool {
        try currentAttempt(ofStep: identity.stepID)?.attempt == identity.attempt
    }
}
