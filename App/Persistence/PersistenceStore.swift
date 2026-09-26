import Foundation
import GRDB

enum ProviderInstanceReadFailure: Equatable, Sendable {
    case invalidBaseURL(String)
    case incompleteCredentialReference
    case unsupportedCredentialKind(String)
}

/// Domain-level failures. Callers get these instead of GRDB errors, so the storage
/// engine's vocabulary never reaches the Runtime or the UI.
enum PersistenceError: Error, Equatable {
    /// The conversation already holds an active parent run.
    case conversationAlreadyHasActiveRun(conversationID: String)

    /// Some other constraint rejected the write — a duplicate id, most likely a
    /// replayed send.
    ///
    /// Kept distinct from the case above on purpose. Reporting every constraint
    /// failure as "the conversation is occupied" would send someone hunting for a
    /// concurrency bug when the real cause is a message id that was already written.
    case constraintViolation

    /// A caller asked for a state change the lifecycle does not allow — finishing a run
    /// with a non-terminal state, or undoing a deletion that was already finalised.
    case invalidTransition(String)

    /// The named conversation does not exist.
    case conversationNotFound(String)

    /// A referenced part does not exist. Not a constraint failure: the caller named
    /// something that was never written, or has already been erased.
    case partNotFound(String)

    case fileAssetNotFound(String)
    case fileAssetVersionNotFound(String)
    case fileAssetVersionMismatch(assetID: String, versionID: String)

    case soulAlreadyExists
    case soulNotFound
    case soulEditConflict(expected: String, actual: String)

    /// The named Provider instance does not exist.
    case providerInstanceNotFound(ProviderInstanceID)

    case submissionIDPayloadConflict(String)

    case unreadableProviderInstance(id: ProviderInstanceID, failure: ProviderInstanceReadFailure)

    /// A create was asked to make an instance whose id is already taken.
    ///
    /// Distinct from `constraintViolation` because it is not a bug in the caller's
    /// concurrency handling — it is a caller trying to write over an existing instance
    /// through the create path, which is the one thing that must not silently succeed.
    case providerInstanceAlreadyExists(ProviderInstanceID)

    /// An instance was read, and something else moved it before the write built on that
    /// read landed.
    ///
    /// Both revisions travel with it, so a caller can say more than "it failed" — but the
    /// point is the refusal, not the message. A stale write is **rejected** rather than
    /// performed, which is what makes a concurrent edit impossible to lose silently: the
    /// losing editor is told, instead of overwriting a change it never saw.
    case providerInstanceEditConflict(
        id: ProviderInstanceID,
        expected: ProviderInstanceEditRevision,
        actual: ProviderInstanceEditRevision
    )

    /// An instance's stored revision is not a counter this build can advance.
    ///
    /// Covers both counters on the row — `configRevision`, which a caller cannot parse,
    /// and `editRevision`, which is already at the end of its range. Its own case rather
    /// than the catch-all below, because it is the one mutation failure that is a
    /// statement about the *data* rather than about the write: the row reads fine, and
    /// what it holds cannot be edited safely. Reported rather than defaulted —
    /// `ConfigRevision.next()` explains why the fallback was the dangerous direction.
    ///
    /// There is no repair path yet. Refusing leaves such an instance uneditable until
    /// something resets it, which is worse for the user than the old silent renumber and
    /// strictly better for every run frozen against the value it would have collided
    /// with. A store that can hold an uncountable revision needs a way to fix one; that
    /// is its own piece of work, not a reason to renumber silently.
    case providerInstanceRevisionUnreadable(id: ProviderInstanceID, rawValue: String)

    /// The write failed for a reason that is not one of the above — a storage-engine
    /// failure, most likely.
    ///
    /// Exists so that **no GRDB type reaches a caller**: `RecordError` and
    /// `DatabaseError` belong to the engine, and this enum is the store's vocabulary.
    /// The underlying description travels with it so the reason is not discarded along
    /// with the type. Nothing secret can be in it — the table holds a credential
    /// *reference*, and `SecretValue` is not `Codable`.
    case providerInstanceMutationFailed(id: ProviderInstanceID, reason: String)

    /// The named run does not exist.
    case runNotFound(String)

    /// The named tool call does not exist.
    case toolCallNotFound(String)

    /// A run row was read, and its frozen request seed could not be understood.
    ///
    /// Distinct from a database failure, and deliberately so: the row was read fine, and
    /// what it held could not be. The row's id travels with the failure so a caller can
    /// say *which* run is unreadable, and the reason separates "written before
    /// versioning" from "written by this build and damaged".
    case unreadableRequestConfigSeed(runID: String, failure: RequestConfigSeedReadFailure)
}

extension PersistenceError {
    /// The refusal shared by the lifecycle guards: the conversation is not where the
    /// mutation says it is. One place, so the wording cannot drift between the
    /// deletion-side guards and the send-side guard.
    static func invalidLifecycleTransition(
        expected: ConversationLifecycle,
        actual: ConversationLifecycle
    ) -> PersistenceError {
        .invalidTransition("expected \(expected.rawValue) but the conversation is \(actual.rawValue)")
    }
}

/// Why a run's frozen request seed could not be read.
///
/// The persistence-facing vocabulary for `RequestConfigSeed.FormatError`. Translated
/// rather than re-exported: `PersistenceError` is what callers of the store see, and a
/// Provider type inside it would put the adapter's vocabulary in front of the Runtime.
enum RequestConfigSeedReadFailure: Equatable {
    /// Written before the seed carried a version. Reported, not migrated — see `P6`.
    case unversioned
    /// Written by a build whose format this one does not know.
    case unsupportedVersion(Int)
    /// Written by this build, and damaged since.
    case malformedCurrentVersion(Int)
    /// Not the seed's JSON at all.
    case malformedPayload

    init(_ error: RequestConfigSeed.FormatError) {
        switch error {
        case .unversioned: self = .unversioned
        case .unsupportedVersion(let version): self = .unsupportedVersion(version)
        case .malformedCurrentVersion(let version): self = .malformedCurrentVersion(version)
        }
    }
}

/// Everything one send commit writes, as a single unit.
///
/// Grouped into one type rather than passed as loose arguments because these six
/// things are not independently meaningful: a message whose run is missing is a
/// conversation nothing can resume, and a run whose seed is missing cannot be
/// replayed. Making them one value makes "forgot to write the seed" a compile error
/// instead of a corrupted row.
struct SendCommit: Sendable {
    var conversation: ConversationRecord
    var message: MessageRecord
    var parts: [MessagePartRecord]
    var attachments: [MessageAttachmentRecord] = []
    var quoteReferences: [MessageQuoteReferenceRecord] = []
    var run: AgentRunRecord
}

/// The data layer's public surface.
///
/// Not a database-abstraction layer. ADR-0001 is settled, so nothing here exists to
/// keep GRDB swappable; the point is that **transaction rules live in one place** and
/// that callers cannot accidentally write half of a compound operation.
///
/// `Sendable` is declared rather than left to inference. It would be inferred anyway —
/// the only stored property is `ZenDatabase`, which is `Sendable` — but a conformance
/// to a `Sendable`-refining protocol declared in a different file (as
/// `CredentialMetadataRepository` is) must live here, next to the type. Being explicit
/// is also the honest description: this is meant to be shareable, not accidentally so.
struct PersistenceStore: Sendable {
    let database: ZenDatabase

    init(database: ZenDatabase) {
        self.database = database
    }

    // MARK: - Send commit

    /// Commits a user turn and creates its parent run **in one transaction**.
    ///
    /// The shape is the point. The alternative — exposing `insert(message:)` and
    /// `insert(run:)` separately — relies on every caller remembering to wrap them,
    /// and one caller that forgets produces a half-state that only shows up as a
    /// conversation that cannot be resumed. Here, all-or-nothing is the only thing
    /// the API can express.
    ///
    /// Throws `PersistenceError.conversationAlreadyHasActiveRun` when the conversation
    /// is already occupied, and `PersistenceError.invalidTransition` when the
    /// conversation has left `.visible` — a send must not move a conversation across
    /// the deletion lifecycle in either direction.
    ///
    /// **Two layers, and the order matters.** The explicit check inside the transaction
    /// exists to produce a precise error message; it is *not* what guarantees the
    /// invariant. The partial unique index is. Removing the index because "the store
    /// already checks" would put the whole guarantee back on application discipline,
    /// which is the thing the spike ruled out.
    @discardableResult
    func commitUserTurnAndCreateParentRun(_ commit: SendCommit) throws -> String? {
        var claimed = commit.run
        // The active-slot rule is applied in exactly one place. Callers pass the run's
        // state and nothing else; forgetting to maintain a derived column is not a
        // mistake they can make.
        claimed.activeSlot = Self.activeSlot(for: claimed)
        let conversationID = claimed.conversationID

        // Bound to a `let` before the closure: the write block is `@Sendable`, so it
        // may not capture the mutable local above.
        let run = claimed

        do {
            return try database.write { db -> String? in
                if let submissionID = run.submissionID,
                   let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM agentRun WHERE submissionID = ?",
                    arguments: [submissionID]
                   ) {
                    let existing = try Self.decodeRun(row)
                    guard existing.submissionDigest == run.submissionDigest else {
                        throw PersistenceError.submissionIDPayloadConflict(submissionID)
                    }
                    return existing.id
                }

                // A send must not change a conversation's lifecycle: the upsert below
                // writes the whole snapshot row. A snapshot read before a deletion
                // began would resurrect the conversation, and one read during the undo
                // window would re-hide a conversation the user just restored. Refuse
                // unless both the stored row and the snapshot say `.visible`; a
                // missing row is the normal first send. Keyed on the run's
                // conversationID — the id the message and run actually land on — and
                // checked first, so a deleted conversation is never reported as merely
                // busy.
                if let existing = try ConversationRecord.fetchOne(db, key: conversationID) {
                    guard existing.lifecycle == .visible else {
                        throw PersistenceError.invalidLifecycleTransition(
                            expected: .visible,
                            actual: existing.lifecycle
                        )
                    }
                    guard commit.conversation.lifecycle == .visible else {
                        throw PersistenceError.invalidLifecycleTransition(
                            expected: .visible,
                            actual: commit.conversation.lifecycle
                        )
                    }
                }

                let occupied = try AgentRunRecord
                    .filter(Column("activeSlot") == conversationID)
                    .fetchCount(db) > 0
                guard !occupied else {
                    throw PersistenceError.conversationAlreadyHasActiveRun(conversationID: conversationID)
                }

                try commit.conversation.upsert(db)
                try commit.message.insert(db)
                for part in commit.parts {
                    try part.insert(db)
                }

                for attachment in commit.attachments {
                    try Self.validateAttachment(attachment, in: db)
                    try attachment.insert(db)
                }

                try Self.validateQuoteReferences(commit.quoteReferences, for: commit.message)
                for quoteReference in commit.quoteReferences {
                    try quoteReference.insert(db)
                }

                try run.insert(db)
                return nil
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            if let submissionID = run.submissionID,
               let existing = try self.run(submissionID: submissionID) {
                guard existing.submissionDigest == run.submissionDigest else {
                    throw PersistenceError.submissionIDPayloadConflict(submissionID)
                }
                return existing.id
            }
            throw PersistenceError.constraintViolation
        }
    }

    private static func validateQuoteReferences(
        _ references: [MessageQuoteReferenceRecord],
        for message: MessageRecord
    ) throws {
        for (sequence, reference) in references.enumerated() {
            guard reference.messageID == message.id,
                  reference.sequence == sequence,
                  !reference.id.isEmpty,
                  !reference.sourceConversationID.isEmpty,
                  !reference.sourceMessageID.isEmpty,
                  !reference.sourcePartID.isEmpty,
                  reference.sourceUTF16Start >= 0,
                  reference.sourceUTF16Length > 0,
                  !reference.snapshot.isEmpty
            else {
                throw PersistenceError.invalidTransition(
                    "quote references must target the committed user message in sequence order"
                )
            }
        }
    }

    /// The conditional-uniqueness slot: the conversation id while a **parent** run is
    /// active, `nil` otherwise.
    ///
    /// Child runs are excluded deliberately. A child run is active too, but the
    /// per-conversation slot belongs to its parent — and if a child occupied the same
    /// slot, the first subagent would collide with the run that spawned it.
    ///
    /// "Active" is `!state.isTerminal`, defined once on `RunState`. So `suspended` and
    /// `stopping` hold the slot; only `completed`, `failed` and `cancelled` release it.
    static func activeSlot(for run: AgentRunRecord) -> String? {
        guard run.kind == .parent, run.state.isActive else { return nil }
        return run.conversationID
    }

    // MARK: - Run lifecycle

    /// Marks a run terminal and releases its active slot.
    ///
    /// The slot is released here rather than by the caller for the same reason it is
    /// claimed there: `stopping` and `suspended` must keep holding it, and a caller
    /// that clears the slot a moment too early would let a second parent run start
    /// while the first is still unwinding.
    ///
    /// Only terminal states release it — enforced below, not merely documented.
    func finishRun(id: String, state: RunState, endReason: EndReason, at now: Date = Date()) throws {
        guard state.isTerminal else {
            throw PersistenceError.invalidTransition(
                "finishRun requires a terminal state; got \(state.rawValue)"
            )
        }

        // Derived rather than listed: the pre-state rule is "not terminal", and
        // `isTerminal` is the one definition of terminal.
        let terminal = RunState.allCases.filter(\.isTerminal).map(\.rawValue)
        let questionMarks = databaseQuestionMarks(count: terminal.count)

        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE agentRun
                    SET state = ?, endReason = ?, activeSlot = NULL, updatedAt = ?
                    WHERE id = ? AND state NOT IN (\(questionMarks))
                    """,
                arguments: StatementArguments(
                    [state.rawValue, endReason.rawValue, now, id]
                        + terminal.map { $0 as (any DatabaseValueConvertible)? }
                )
            )
            if db.changesCount == 0 {
                try Self.refuseMissedStateUpdate(
                    db,
                    table: "agentRun",
                    id: id,
                    precondition: "a non-terminal state",
                    notFound: PersistenceError.runNotFound(id)
                )
            }
        }
    }

    // MARK: - Reads

    func conversation(id: String) throws -> ConversationRecord? {
        try database.read { db in
            try ConversationRecord.fetchOne(db, key: id)
        }
    }

    func messages(inConversation id: String) throws -> [MessageRecord] {
        try database.read { db in
            try MessageRecord
                .filter(Column("conversationID") == id)
                .order(Column("sequence"))
                .fetchAll(db)
        }
    }

    func run(id: String) throws -> AgentRunRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM agentRun WHERE id = ?", arguments: [id]
            ) else { return nil }
            return try Self.decodeRun(row)
        }
    }

    func run(submissionID: String) throws -> AgentRunRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM agentRun WHERE submissionID = ?",
                arguments: [submissionID]
            ) else { return nil }
            return try Self.decodeRun(row)
        }
    }

    /// Reads one run row, reporting an unreadable seed as a typed failure.
    ///
    /// `AgentRunRecord` is `Codable`, so GRDB decodes the seed column itself and a row
    /// written by an older build surfaces as **GRDB's own decoding error** — a
    /// storage-engine type, in front of the caller, about a payload problem. The seed is
    /// therefore read and checked *before* GRDB is asked to decode the row, so the
    /// diagnosis is ours rather than the engine's.
    ///
    /// The seed is decoded here and then again inside `AgentRunRecord(row:)`. That is one
    /// decode more than strictly needed, and it is deliberate: validating through the
    /// same implementation the reader uses means the check and the read cannot disagree,
    /// and it avoids a hand-written column-by-column mapping that could drift from the
    /// schema — a drift nothing here would catch until a row was written and read back.
    private static func decodeRun(_ row: Row) throws -> AgentRunRecord {
        let runID: String = row["id"]
        let raw: String = row["requestConfigSeed"]
        try validateSeed(raw, runID: runID)

        do {
            return try AgentRunRecord(row: row)
        } catch {
            // The seed was readable a moment ago on this same row, so this is not a
            // version problem. Something else about the row will not decode, and it
            // still must not escape as a GRDB type.
            throw PersistenceError.unreadableRequestConfigSeed(runID: runID, failure: .malformedPayload)
        }
    }

    /// Reads the seed and reports why it could not be, in the store's vocabulary.
    private static func validateSeed(_ raw: String, runID: String) throws {
        guard let data = raw.data(using: .utf8) else {
            throw PersistenceError.unreadableRequestConfigSeed(runID: runID, failure: .malformedPayload)
        }
        do {
            _ = try JSONDecoder().decode(RequestConfigSeed.self, from: data)
        } catch let failure as RequestConfigSeed.FormatError {
            throw PersistenceError.unreadableRequestConfigSeed(
                runID: runID, failure: RequestConfigSeedReadFailure(failure)
            )
        } catch {
            // Not the seed's format at all: truncated text, another encoding, a column
            // something wrote by hand.
            throw PersistenceError.unreadableRequestConfigSeed(runID: runID, failure: .malformedPayload)
        }
    }

    /// Runs still holding the conversation's active slot.
    ///
    /// Counted from the slot rather than from a state list, so the query cannot drift
    /// from the rule the index enforces.
    func activeParentRuns(inConversation id: String) throws -> [AgentRunRecord] {
        try database.read { db in
            // Row by row, so an unreadable seed is reported as *that run's* failure with
            // its id, rather than as the whole query failing with a GRDB error.
            //
            // The signature stays `throws -> [AgentRunRecord]`. The partial unique index
            // on `activeSlot` means this returns at most one row, so "the batch failed"
            // and "this row failed" are the same event — there is no larger result to
            // salvage by reporting per-row.
            try Row
                .fetchAll(
                    db,
                    sql: "SELECT * FROM agentRun WHERE activeSlot = ?",
                    arguments: [id]
                )
                .map(Self.decodeRun)
        }
    }

    // MARK: - Guarded updates

    /// The refusal behind a state-preconditioned update that touched no row.
    ///
    /// Two different failures hide behind "nothing changed", and they must stay
    /// distinguishable: the row never existed (`notFound`), or it exists in a state
    /// the precondition refuses (`invalidTransition`, naming the state found). The
    /// read happens inside the same write transaction as the update, so the answer
    /// cannot be overtaken before it is reported.
    static func refuseMissedStateUpdate(
        _ db: Database,
        table: String,
        id: String,
        precondition: String,
        notFound: PersistenceError
    ) throws -> Never {
        let current = try String.fetchOne(
            db,
            sql: "SELECT state FROM \(table) WHERE id = ?",
            arguments: [id]
        )
        guard let current else { throw notFound }
        throw PersistenceError.invalidTransition(
            "\(table) \(id) is \(current); this update requires \(precondition)"
        )
    }
}
