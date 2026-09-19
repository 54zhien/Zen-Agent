import Foundation

@testable import ZenAgent

/// Builders shared by the persistence invariant tests.
///
/// Fixed timestamps, so a failing assertion is about the rule under test rather than
/// about when it happened to run.
enum Fixtures {

    static let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    static func conversation(
        id: String = "c1",
        title: String = "A conversation",
        lifecycle: ConversationLifecycle = .visible
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: title,
            createdAt: epoch,
            updatedAt: epoch,
            userActiveAt: epoch,
            pinned: false,
            lifecycle: lifecycle
        )
    }

    static func message(
        id: String,
        conversationID: String = "c1",
        role: MessageRole = .user,
        sequence: Int = 0
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            conversationID: conversationID,
            role: role,
            sequence: sequence,
            createdAt: epoch
        )
    }

    static func textPart(
        id: String,
        messageID: String,
        sequence: Int = 0,
        text: String = "hello"
    ) -> MessagePartRecord {
        MessagePartRecord(
            id: id,
            messageID: messageID,
            sequence: sequence,
            kind: .text,
            state: .completed,
            payload: #"{"text":"\#(text)"}"#
        )
    }

    static func run(
        id: String,
        conversationID: String = "c1",
        kind: RunKind = .parent,
        state: RunState = .preparing,
        parentRunID: String? = nil,
        triggerMessageID: String? = nil,
        responseMessageID: String? = nil,
        retryOfRunID: String? = nil
    ) -> AgentRunRecord {
        AgentRunRecord(
            id: id,
            conversationID: conversationID,
            kind: kind,
            parentRunID: parentRunID,
            state: state,
            endReason: nil,
            recoveryAction: nil,
            suspendReason: nil,
            triggerMessageID: triggerMessageID,
            responseMessageID: responseMessageID,
            retryOfRunID: retryOfRunID,
            requestConfigSeed: #"{"model":"deepseek-chat","reasoningEffort":"medium"}"#,
            executionSnapshot: nil,
            createdAt: epoch,
            updatedAt: epoch,
            // Never set by hand. `PersistenceStore` derives it, and having callers
            // compute it is exactly the mistake the derived-value design prevents.
            activeSlot: nil
        )
    }

    /// A throwaway store path, for the tests that have to close and reopen.
    ///
    /// The caller is responsible for `cleanUp` — and for having closed the store first,
    /// since deleting a SQLite file while a connection still holds it makes libsqlite3
    /// log a `BUG IN CLIENT` line that makes real problems harder to spot.
    static func scratchPath(name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "zen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func toolCall(
        id: String,
        runID: String,
        action: String = "files.write",
        state: ToolCallState = .prepared,
        attempt: Int = 1,
        intent: String? = #"{"action":"files.write","target":"file:n1"}"#
    ) -> ToolCallRecord {
        ToolCallRecord(
            id: id,
            agentRunID: runID,
            action: action,
            state: state,
            executionIntent: intent,
            attempt: attempt,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    /// A part that is still streaming, as the Composer would create it.
    static func streamingPart(
        id: String,
        messageID: String,
        sequence: Int = 1,
        text: String = ""
    ) -> MessagePartRecord {
        MessagePartRecord(
            id: id,
            messageID: messageID,
            sequence: sequence,
            kind: .text,
            state: .streaming,
            payload: #"{"text":"\#(text)"}"#
        )
    }

    /// One complete send: conversation, message, parts and the parent run.
    static func send(
        conversationID: String = "c1",
        messageID: String,
        runID: String,
        runState: RunState = .preparing,
        runKind: RunKind = .parent
    ) -> SendCommit {
        SendCommit(
            conversation: conversation(id: conversationID),
            message: message(id: messageID, conversationID: conversationID),
            parts: [textPart(id: "\(messageID)-p0", messageID: messageID)],
            run: run(
                id: runID,
                conversationID: conversationID,
                kind: runKind,
                state: runState,
                triggerMessageID: messageID
            )
        )
    }
}
