import Foundation
import Testing

import GRDB
import SwiftData

/// Scenarios E and F — the deletion lifecycle.
///
/// One lifecycle, two questions that fail independently, so they are asserted
/// independently. Keeping them as one test would mean a tombstone regression and an
/// undo regression both surfaced as "delete lifecycle failed", and the next person
/// would have to bisect to find out which:
///
/// - **E** — during the undo window the body is intact, and undo restores the
///   *complete* conversation. An undo that returns an empty shell is the failure
///   this exists to catch.
/// - **F** — once finalised the body goes, but the minimal record of an
///   `indeterminate` external operation survives. It must not be reachable by
///   cascade from the conversation.
///
/// F is one of the blueprint's few "must outlive its parent" constraints: the
/// tombstone exists precisely because the thing that owned it is gone.
@Suite("Scenarios E and F — deletion lifecycle")
struct ScenarioEFTests {

    // MARK: - GRDB

    private func createDeletionTables(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                // visible | pendingDeletion | finalizedDeletion
                t.column("lifecycle", .text).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("conversationID", .text).notNull()
                t.column("body", .text).notNull()
            }
            try db.create(table: "toolCall") { t in
                t.primaryKey("id", .text)
                t.column("conversationID", .text).notNull()
                t.column("state", .text).notNull()
            }
            // Deliberately NOT declared with a foreign key to conversation: the
            // tombstone has to outlive the parent, and an ON DELETE CASCADE would be
            // exactly the wrong shape.
            try db.create(table: "tombstone") { t in
                t.primaryKey("toolCallID", .text)
                t.column("action", .text).notNull()
                t.column("destinationFingerprint", .text).notNull()
                t.column("attempt", .integer).notNull()
                t.column("status", .text).notNull()
            }
        }
    }

    private func seedConversation(_ queue: DatabaseQueue, toolCallState: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO conversation (id, lifecycle) VALUES ('c1', 'visible')"
            )
            try db.execute(
                sql: "INSERT INTO message (id, conversationID, body) VALUES ('m1', 'c1', 'the body')"
            )
            try db.execute(
                sql: "INSERT INTO toolCall (id, conversationID, state) VALUES ('t1', 'c1', ?)",
                arguments: [toolCallState]
            )
        }
    }

    @Test("E · GRDB — the undo window keeps the body, and undo restores it whole")
    func grdbUndoWindow() throws {
        let url = try makeScratchPath(name: "grdb-e.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        try createDeletionTables(queue)
        try seedConversation(queue, toolCallState: "succeeded")

        // Commit the delete: hidden from ordinary listing, still undoable.
        try queue.write { db in
            try db.execute(sql: "UPDATE conversation SET lifecycle = 'pendingDeletion' WHERE id = 'c1'")
        }

        let duringWindow = try grdbDeletionState(path)
        #expect(
            duringWindow.visible == 0,
            "a pending-deletion conversation must be gone from ordinary listing; found \(duringWindow.visible)"
        )
        #expect(
            duringWindow.bodies == ["the body"],
            """
            the undo window must keep the body intact — undo is supposed to restore a \
            conversation, not an empty shell. Found \(duringWindow.bodies)
            """
        )

        // Undo.
        try queue.write { db in
            try db.execute(sql: "UPDATE conversation SET lifecycle = 'visible' WHERE id = 'c1'")
        }

        let afterUndo = try grdbDeletionState(path)
        #expect(afterUndo.visible == 1, "undo must return the conversation to ordinary listing")
        #expect(
            afterUndo.bodies == ["the body"],
            "undo must restore the complete conversation; found \(afterUndo.bodies)"
        )
    }

    @Test("F · GRDB — finalising removes the body but keeps the indeterminate tombstone")
    func grdbTombstoneSurvives() throws {
        let url = try makeScratchPath(name: "grdb-f.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        try createDeletionTables(queue)
        try seedConversation(queue, toolCallState: "indeterminate")

        // Finalising: the tombstone is written first, then the body goes.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO tombstone (toolCallID, action, destinationFingerprint, attempt, status)
                SELECT id, 'files.write', 'file:n1', 1, state FROM toolCall WHERE id = 't1'
                """)
            try db.execute(sql: "DELETE FROM message WHERE conversationID = 'c1'")
            try db.execute(sql: "DELETE FROM toolCall WHERE conversationID = 'c1'")
            try db.execute(sql: "UPDATE conversation SET lifecycle = 'finalizedDeletion' WHERE id = 'c1'")
        }

        let state = try grdbTombstoneState(path)
        #expect(state.bodies == 0, "finalising must remove the body; found \(state.bodies) message(s)")
        #expect(state.toolCalls == 0, "finalising must remove the tool calls; found \(state.toolCalls)")
        #expect(
            state.tombstones == 1,
            """
            the indeterminate operation's minimal record must outlive the conversation. \
            Found \(state.tombstones) tombstone(s)
            """
        )
        #expect(
            state.tombstoneAction == "files.write" && state.tombstoneDestination == "file:n1",
            "the tombstone must keep enough to identify the external operation"
        )
    }

    // MARK: - GRDB helpers

    private func grdbDeletionState(_ path: String) throws -> (visible: Int, bodies: [String]) {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.read { db in
            (
                visible: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM conversation WHERE lifecycle = 'visible'"
                ) ?? -1,
                bodies: try String.fetchAll(db, sql: "SELECT body FROM message ORDER BY id")
            )
        }
    }

    private func grdbTombstoneState(
        _ path: String
    ) throws -> (bodies: Int, toolCalls: Int, tombstones: Int, tombstoneAction: String?, tombstoneDestination: String?) {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT action, destinationFingerprint FROM tombstone LIMIT 1")
            return (
                bodies: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1,
                toolCalls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM toolCall") ?? -1,
                tombstones: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") ?? -1,
                tombstoneAction: row?["action"] as String?,
                tombstoneDestination: row?["destinationFingerprint"] as String?
            )
        }
    }

    // MARK: - SwiftData

    @Test("E · SwiftData — the undo window keeps the body, and undo restores it whole")
    @MainActor
    func swiftDataUndoWindow() throws {
        let url = try makeScratchPath(name: "swiftdata-e.store")
        defer { cleanUp(url) }

        let container = try ModelContainer(
            for: DeletableConversation.self, DeletableMessage.self,
            configurations: ModelConfiguration(url: url)
        )

        do {
            let context = ModelContext(container)
            let conversation = DeletableConversation(id: "c1", lifecycle: "visible")
            context.insert(conversation)
            context.insert(DeletableMessage(id: "m1", body: "the body", conversation: conversation))
            try context.save()
        }

        do {
            let context = ModelContext(container)
            guard let conversation = try context.fetch(FetchDescriptor<DeletableConversation>()).first else {
                Issue.record("expected the seeded conversation to exist")
                return
            }
            conversation.lifecycle = "pendingDeletion"
            try context.save()
        }

        let duringWindow = try swiftDataDeletionState(container)
        #expect(
            duringWindow.visible == 0,
            "a pending-deletion conversation must be gone from ordinary listing; found \(duringWindow.visible)"
        )
        #expect(
            duringWindow.bodies == ["the body"],
            """
            the undo window must keep the body intact — undo is supposed to restore a \
            conversation, not an empty shell. Found \(duringWindow.bodies)
            """
        )

        do {
            let context = ModelContext(container)
            guard let conversation = try context.fetch(FetchDescriptor<DeletableConversation>()).first else {
                Issue.record("expected the conversation to still exist during the undo window")
                return
            }
            conversation.lifecycle = "visible"
            try context.save()
        }

        let afterUndo = try swiftDataDeletionState(container)
        #expect(afterUndo.visible == 1, "undo must return the conversation to ordinary listing")
        #expect(
            afterUndo.bodies == ["the body"],
            "undo must restore the complete conversation; found \(afterUndo.bodies)"
        )
    }

    @Test("F · SwiftData — finalising removes the body but keeps the indeterminate tombstone")
    @MainActor
    func swiftDataTombstoneSurvives() throws {
        let url = try makeScratchPath(name: "swiftdata-f.store")
        defer { cleanUp(url) }

        let container = try ModelContainer(
            for: DeletableConversation.self, DeletableMessage.self,
            IndeterminateToolCall.self, OperationTombstone.self,
            configurations: ModelConfiguration(url: url)
        )

        do {
            let context = ModelContext(container)
            let conversation = DeletableConversation(id: "c1", lifecycle: "visible")
            context.insert(conversation)
            context.insert(DeletableMessage(id: "m1", body: "the body", conversation: conversation))
            context.insert(IndeterminateToolCall(id: "t1", conversation: conversation))
            // The tombstone has no relationship to the conversation — deliberately.
            // Anything reachable by cascade would be swept away with the parent, and
            // this record exists precisely because the parent is gone.
            context.insert(OperationTombstone(
                toolCallID: "t1",
                action: "files.write",
                destinationFingerprint: "file:n1",
                attempt: 1,
                status: "indeterminate"
            ))
            try context.save()
        }

        do {
            let context = ModelContext(container)
            guard let conversation = try context.fetch(FetchDescriptor<DeletableConversation>()).first else {
                Issue.record("expected the seeded conversation to exist")
                return
            }
            context.delete(conversation)
            try context.save()
        }

        let state = try swiftDataTombstoneState(container)
        #expect(state.bodies == 0, "finalising must remove the body; found \(state.bodies) message(s)")
        #expect(state.toolCalls == 0, "finalising must cascade the tool calls; found \(state.toolCalls)")
        #expect(
            state.tombstones == 1,
            """
            the indeterminate operation's minimal record must outlive the conversation. \
            Found \(state.tombstones) tombstone(s)
            """
        )
        #expect(
            state.tombstoneAction == "files.write" && state.tombstoneDestination == "file:n1",
            "the tombstone must keep enough to identify the external operation"
        )
    }

    // MARK: - SwiftData helpers

    @MainActor
    private func swiftDataDeletionState(
        _ container: ModelContainer
    ) throws -> (visible: Int, bodies: [String]) {
        let context = ModelContext(container)
        let visible = try context.fetch(FetchDescriptor<DeletableConversation>())
            .filter { $0.lifecycle == "visible" }
            .count
        let bodies = try context.fetch(FetchDescriptor<DeletableMessage>()).map(\.body).sorted()
        return (visible: visible, bodies: bodies)
    }

    @MainActor
    private func swiftDataTombstoneState(
        _ container: ModelContainer
    ) throws -> (bodies: Int, toolCalls: Int, tombstones: Int, tombstoneAction: String?, tombstoneDestination: String?) {
        let context = ModelContext(container)
        let tombstone = try context.fetch(FetchDescriptor<OperationTombstone>()).first
        return (
            bodies: try context.fetchCount(FetchDescriptor<DeletableMessage>()),
            toolCalls: try context.fetchCount(FetchDescriptor<IndeterminateToolCall>()),
            tombstones: try context.fetchCount(FetchDescriptor<OperationTombstone>()),
            tombstoneAction: tombstone?.action,
            tombstoneDestination: tombstone?.destinationFingerprint
        )
    }
}

// MARK: - Probe models

/// Throwaway models for E and F. Not drafts of product entities.

@Model
final class DeletableConversation {
    var id: String
    /// visible | pendingDeletion | finalizedDeletion
    var lifecycle: String

    /// Cascading on purpose: this is what makes the body disappear when the
    /// conversation is finalised, and the inverse makes the relationship navigable
    /// from both ends.
    @Relationship(deleteRule: .cascade, inverse: \DeletableMessage.conversation)
    var messages: [DeletableMessage] = []

    @Relationship(deleteRule: .cascade, inverse: \IndeterminateToolCall.conversation)
    var toolCalls: [IndeterminateToolCall] = []

    init(id: String, lifecycle: String) {
        self.id = id
        self.lifecycle = lifecycle
    }
}

@Model
final class DeletableMessage {
    var id: String
    var body: String
    var conversation: DeletableConversation?

    init(id: String, body: String, conversation: DeletableConversation) {
        self.id = id
        self.body = body
        self.conversation = conversation
    }
}

@Model
final class IndeterminateToolCall {
    var id: String
    var conversation: DeletableConversation?

    init(id: String, conversation: DeletableConversation) {
        self.id = id
        self.conversation = conversation
    }
}

/// Carries no relationship and no inverse — see the note in F.
@Model
final class OperationTombstone {
    var toolCallID: String
    var action: String
    var destinationFingerprint: String
    var attempt: Int
    var status: String

    init(toolCallID: String, action: String, destinationFingerprint: String, attempt: Int, status: String) {
        self.toolCallID = toolCallID
        self.action = action
        self.destinationFingerprint = destinationFingerprint
        self.attempt = attempt
        self.status = status
    }
}
