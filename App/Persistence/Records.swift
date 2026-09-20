import Foundation
import GRDB

// MARK: - Vocabulary
//
// These mirror `Zen-Agent-Blueprint → Design/CONTEXT.md`. They are strings on disk
// and enums in code, so a typo becomes a compile error rather than a row nothing can
// read.

/// Where a conversation is in its deletion lifecycle.
///
/// Three states rather than a `isDeleted` flag: the undo window needs a state where
/// the conversation is hidden from ordinary listing but its body is entirely intact.
/// A boolean cannot express that, and collapsing it is how undo ends up restoring an
/// empty shell.
enum ConversationLifecycle: String, Codable, Sendable {
    case visible
    case pendingDeletion
    case finalizedDeletion
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum MessagePartKind: String, Codable, Sendable {
    case text
    case reasoning
    case toolCall
    case toolResult
}

enum MessagePartState: String, Codable, Sendable {
    case pending
    case streaming
    case completed
    case failed
    case cancelled
}

enum RunKind: String, Codable, Sendable {
    case parent
    case child
}

/// Where a run is. Answers "where is it now" and nothing else.
enum RunState: String, CaseIterable, Codable, Sendable {
    case preparing
    case requestingModel
    case streaming
    case toolRequested
    case waitingForApproval
    case executingTools
    case continuing
    case stopping
    case suspended
    case recovering
    case completed
    case failed
    case cancelled
}

extension RunState {
    /// The whole definition, in one place.
    ///
    /// `active Parent Run` means *any non-terminal parent run* — `stopping`,
    /// `suspended` and `recovering` included. That single rule closes five paths at
    /// once (send, stop, delete, recover, cold start), which is why it is expressed
    /// once here rather than restated at each call site with a slightly different
    /// list of states.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool { !isTerminal }
}

/// Why a run ended. Only meaningful for a terminal run.
enum EndReason: String, Codable, Sendable {
    case completed
    case cancelledByUser
    case totalTimeout
    case stepTimeout
    case stepLimit
    case streamInterrupted
    case streamInactivityTimeout
    case providerFailed
    case toolFailed
    case toolOutcomeUnknown
    case credentialExpired
    case dependencyUnavailable
    case unrecoverable
}

/// What should happen to a run that was suspended or invalidated.
///
/// Separate from `EndReason` on purpose. Asking "why did it end" and "what should be
/// done with it" are different questions, and a run that needs handling has not
/// necessarily ended.
enum RecoveryAction: String, Codable, Sendable {
    case resume
    case reprepare
    case restart
    case fail
    case invalidate
}

enum SuspendReason: String, Codable, Sendable {
    case backgrounded
    case networkLost
    case approvalPending
    case authRequired
}

enum ToolCallState: String, CaseIterable, Codable, Sendable {
    case validated
    case waitingForApproval
    case waitingForSystemPermissionConsent
    case approved
    /// Intent frozen, external call not yet attempted.
    case prepared
    /// Marker committed immediately before the external call. A crash anywhere after
    /// this point means the call *might* have happened.
    case dispatched
    case succeeded
    case failed
    case rejected
    case cancelled
    /// Cancelled before dispatch — no external side effect, safe to re-decide.
    case notExecuted
    /// Possibly dispatched, outcome unknown. Never auto-retried.
    case indeterminate
}

/// What recovery is allowed to do with a tool call found in a given state.
///
/// This is the rule that makes `prepared` and `dispatched` worth separating. It lives
/// next to the state it reads rather than in a future Tool Runtime, because it is a
/// statement about what the state *means* — and because it is the one decision that
/// must not be re-derived differently in two places.
enum ToolRecoveryDisposition: Equatable, Sendable {
    /// The external call provably never happened. Safe to decide afresh.
    case mayDispatch
    /// It may have happened. Report it and stop; never retry automatically.
    case mustReportIndeterminate
    /// Already finished. Nothing to decide.
    case settled
}

extension ToolCallState {
    /// Nothing further will happen to the call. `.waitingForApproval` and
    /// `.waitingForSystemPermissionConsent` are settled but not terminal: they can
    /// still move on.
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .rejected, .cancelled, .notExecuted: return true
        default: return false
        }
    }

    var recoveryDisposition: ToolRecoveryDisposition {
        switch self {
        case .prepared, .validated, .approved:
            // Reached only before the dispatch marker was committed, so nothing left
            // the process.
            return .mayDispatch
        case .dispatched:
            // The marker is committed immediately *before* the call, deliberately, so
            // a crash anywhere after it leaves genuine uncertainty. Assuming "it
            // probably didn't happen" and retrying is how a write is applied twice.
            return .mustReportIndeterminate
        case .indeterminate:
            return .mustReportIndeterminate
        case .succeeded, .failed, .rejected, .cancelled, .notExecuted:
            return .settled
        case .waitingForApproval, .waitingForSystemPermissionConsent:
            return .settled
        }
    }
}

// MARK: - Records
//
// Plain value types. GRDB conformity comes from `Codable`, which is why these are
// structs rather than `Record` subclasses — the ADR records that GRDB itself advises
// this before strict concurrency is enabled, and strict concurrency is on here.

struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "conversation"

    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Business ordering field. Updated only by user actions that change the
    /// conversation's working progress — never by streaming, background work or
    /// merely opening it.
    var userActiveAt: Date
    var pinned: Bool
    var lifecycle: ConversationLifecycle
}

struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "message"

    var id: String
    var conversationID: String
    var role: MessageRole
    var sequence: Int
    var createdAt: Date
}

struct MessagePartRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "messagePart"

    var id: String
    var messageID: String
    var sequence: Int
    var kind: MessagePartKind
    var state: MessagePartState
    /// JSON. Shape depends on `kind`.
    var payload: String
}

struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "agentRun"

    var id: String
    var conversationID: String
    var kind: RunKind
    var parentRunID: String?

    var state: RunState
    var endReason: EndReason?
    var recoveryAction: RecoveryAction?
    var suspendReason: SuspendReason?

    var triggerMessageID: String?
    /// Null when the provider failed before producing anything. No placeholder is
    /// fabricated — the failure is anchored on the triggering user message instead.
    var responseMessageID: String?
    var retryOfRunID: String?

    /// Frozen at send commit; never rewritten afterwards.
    var requestConfigSeed: RequestConfigSeed
    /// JSON, non-secret, completed during preparing. Never rewrites the seed.
    var executionSnapshot: String?

    var createdAt: Date
    var updatedAt: Date

    /// The conditional-uniqueness slot: the conversation id while this run is active,
    /// `nil` once terminal. Only parent runs occupy it — see the schema.
    var activeSlot: String?
}

/// One provider request within a run, and which attempt of it is current.
///
/// The attempt number is the generation token: `(id, attempt)` is what a streaming
/// event carries, and anything arriving for an older attempt is discarded. Without a
/// durable identity for "the request we are actually listening to", a late delta from
/// a stopped or recovered run is indistinguishable from a live one — which is the
/// failure the notes call out at `Agent Runtime.md:340`.
///
/// This is a skeleton. It records identity and ordering; the run's execution snapshot
/// and the use of these identities during recover belong to Stage 2.
struct AgentStepRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "agentStep"

    /// Stable across the step's attempts: a replay is another attempt of the *same*
    /// step, not a new step.
    var stepID: String
    var runID: String
    /// Position of this step within the run.
    var sequence: Int
    /// Increments on every real provider request, including replays.
    var attempt: Int
    var createdAt: Date

    /// The primary key is `(stepID, attempt)`, so the database enforces "one row per
    /// attempt" rather than trusting callers not to insert the same one twice.
    var id: String { "\(stepID)#\(attempt)" }

    /// The identity a streaming event must carry to be accepted.
    var attemptIdentity: AttemptIdentity { AttemptIdentity(stepID: stepID, attempt: attempt) }
}

/// What a streaming event says it belongs to.
///
/// Compared against the current attempt to decide whether to accept an event or drop
/// it as stale. Kept as a value so the comparison is one expression rather than a
/// pair of field checks repeated wherever a delta arrives.
struct AttemptIdentity: Codable, Sendable, Equatable {
    var stepID: String
    var attempt: Int
}

struct ToolCallRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "toolCall"

    var id: String
    var agentRunID: String
    var action: String
    var state: ToolCallState
    /// JSON, normalised and frozen before approval. The executor consumes this same
    /// value, so an approval cannot be redirected to a different target.
    var executionIntent: String?
    var attempt: Int
    var createdAt: Date
    var updatedAt: Date
}

struct OperationTombstoneRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "operationTombstone"

    var toolCallID: String
    var action: String
    var destinationFingerprint: String
    var attempt: Int
    var status: String
    var createdAt: Date

    var id: String { toolCallID }
}
