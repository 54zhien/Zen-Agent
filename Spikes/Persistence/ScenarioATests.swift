import Foundation
import Testing

import GRDB
import SwiftData

/// Raised to force a failure inside the send transaction. See A1.
struct SendInterrupted: Error {}

/// Scenario A — atomic send commit.
///
/// One user action must produce **all or none** of: the committed User Message,
/// the Parent Run, and the frozen request-config seed. The only failing shape is a
/// half-state — a message with no run, or a run with no message — because either
/// one is a conversation the Runtime can neither resume nor explain.
///
/// Split deliberately into two different failures, because they are not the same:
///
/// - **A1** the transaction body fails and must roll back
/// - **A2** the process dies with work in flight and must leave nothing behind
///
/// A dry "it passed" is not the result. Each test reports the counts it observed,
/// and A2 carries a **negative control** — without one, an assertion that no
/// half-state occurred proves nothing, because the test may simply be incapable of
/// seeing one.
@Suite("Scenario A — atomic send")
struct ScenarioATests {

    // MARK: - Shared shapes

    private func createSendTables(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: "userMessage") { t in
                t.primaryKey("id", .text)
                t.column("body", .text).notNull()
            }
            try db.create(table: "parentRun") { t in
                t.primaryKey("id", .text)
                t.column("state", .text).notNull()
            }
        }
    }

    private func insertSend(_ db: Database, messageID: String, runID: String) throws {
        try db.execute(
            sql: "INSERT INTO userMessage (id, body) VALUES (?, ?)",
            arguments: [messageID, "hello"]
        )
        try db.execute(
            sql: "INSERT INTO parentRun (id, state) VALUES (?, ?)",
            arguments: [runID, "preparing"]
        )
    }

    private func sendCounts(_ path: String) throws -> (messages: Int, runs: Int) {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            (
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM userMessage") ?? -1,
                runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parentRun") ?? -1
            )
        }
    }

    private func describe(_ counts: (messages: Int, runs: Int)) -> String {
        "messages=\(counts.messages) runs=\(counts.runs)"
    }

    // MARK: - A1 · GRDB

    @Test("A1 · GRDB — a failure inside the send transaction rolls both writes back")
    func grdbRollback() throws {
        let url = try makeScratchPath(name: "grdb-a1.sqlite")
        defer { cleanUp(url) }
        let queue = try DatabaseQueue(path: url.path())
        try createSendTables(queue)

        var failure: Error?
        do {
            try queue.write { db in
                try insertSend(db, messageID: "m1", runID: "r1")
                throw SendInterrupted()
            }
        } catch {
            failure = error
        }

        #expect(failure is SendInterrupted, "the injected failure must surface; got \(String(describing: failure))")

        let counts = try sendCounts(url.path())
        #expect(
            counts.messages == 0 && counts.runs == 0,
            "a failed send must leave nothing behind; observed \(describe(counts))"
        )
    }

    // MARK: - A2 · GRDB

    /// The negative control. It commits the message and then stops, exactly as an
    /// implementation that used two commits would look after dying between them.
    /// If this cannot observe the half-state, the real assertion below is worthless.
    @Test("A2 · GRDB · control — the split-commit half-state IS observable")
    func grdbSplitCommitIsDetectable() throws {
        let url = try makeScratchPath(name: "grdb-a2-control.sqlite")
        defer { cleanUp(url) }
        let queue = try DatabaseQueue(path: url.path())
        try createSendTables(queue)

        // Commit only the message, then the process "dies" before the run.
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO userMessage (id, body) VALUES (?, ?)",
                arguments: ["m1", "hello"]
            )
        }

        let counts = try sendCounts(url.path())
        #expect(
            counts.messages == 1 && counts.runs == 0,
            """
            control failed: the probe cannot observe a split commit, so any \
            no-half-state result below is meaningless. Observed \(describe(counts))
            """
        )
    }

    @Test("A2 · GRDB — work in flight when the process dies leaves nothing behind")
    func grdbInFlightWorkVanishes() throws {
        let url = try makeScratchPath(name: "grdb-a2.sqlite")
        defer { cleanUp(url) }
        let path = url.path()

        do {
            let queue = try DatabaseQueue(path: path)
            try createSendTables(queue)

            // Both writes issued inside one transaction that is never committed —
            // the process dies here. The connection going away rolls it back.
            try queue.inDatabase { db in
                try db.beginTransaction()
                try insertSend(db, messageID: "m1", runID: "r1")
            }
        }

        let counts = try sendCounts(path)
        #expect(
            counts.messages == 0 && counts.runs == 0,
            """
            an uncommitted send must vanish entirely, never leaving one of its two \
            halves. Observed \(describe(counts)). The control test above shows this \
            probe can see a half-state, so a clean result here means something.
            """
        )
    }

    // MARK: - A1 · SwiftData

    @Test("A1 · SwiftData — a failure inside the send transaction rolls both writes back")
    @MainActor
    func swiftDataRollback() throws {
        let url = try makeScratchPath(name: "swiftdata-a1.store")
        defer { cleanUp(url) }

        let container = try ModelContainer(
            for: SendMessageRecord.self, SendRunRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)

        var failure: Error?
        do {
            try context.transaction {
                context.insert(SendMessageRecord(id: "m1", body: "hello"))
                context.insert(SendRunRecord(id: "r1", state: "preparing"))
                throw SendInterrupted()
            }
        } catch {
            failure = error
        }

        #expect(failure is SendInterrupted, "the injected failure must surface; got \(String(describing: failure))")

        let counts = try swiftDataSendCounts(url)
        #expect(
            counts.messages == 0 && counts.runs == 0,
            "a failed send must leave nothing behind; observed \(describe(counts))"
        )
    }

    // MARK: - A2 · SwiftData

    @Test("A2 · SwiftData · control — the split-commit half-state IS observable")
    @MainActor
    func swiftDataSplitCommitIsDetectable() throws {
        let url = try makeScratchPath(name: "swiftdata-a2-control.store")
        defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: SendMessageRecord.self, SendRunRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.insert(SendMessageRecord(id: "m1", body: "hello"))
            try context.save()   // only the message is committed
        }

        let counts = try swiftDataSendCounts(url)
        #expect(
            counts.messages == 1 && counts.runs == 0,
            """
            control failed: the probe cannot observe a split commit, so any \
            no-half-state result below is meaningless. Observed \(describe(counts))
            """
        )
    }

    @Test("A2 · SwiftData — work in flight when the process dies leaves nothing behind")
    @MainActor
    func swiftDataInFlightWorkVanishes() throws {
        let url = try makeScratchPath(name: "swiftdata-a2.store")
        defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: SendMessageRecord.self, SendRunRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(SendMessageRecord(id: "m1", body: "hello"))
            context.insert(SendRunRecord(id: "r1", state: "preparing"))
            // No save(): the process dies with both objects unsaved.
        }

        let counts = try swiftDataSendCounts(url)
        #expect(
            counts.messages == 0 && counts.runs == 0,
            """
            an uncommitted send must vanish entirely, never leaving one of its two \
            halves. Observed \(describe(counts)). The control test above shows this \
            probe can see a half-state, so a clean result here means something.
            """
        )
    }

    // MARK: - SwiftData helper

    @MainActor
    private func swiftDataSendCounts(_ url: URL) throws -> (messages: Int, runs: Int) {
        let container = try ModelContainer(
            for: SendMessageRecord.self, SendRunRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        return (
            messages: try context.fetchCount(FetchDescriptor<SendMessageRecord>()),
            runs: try context.fetchCount(FetchDescriptor<SendRunRecord>())
        )
    }
}

// MARK: - Probe models

/// Throwaway models for scenario A. Not drafts of product entities.
@Model
final class SendMessageRecord {
    var id: String
    var body: String

    init(id: String, body: String) {
        self.id = id
        self.body = body
    }
}

@Model
final class SendRunRecord {
    var id: String
    var state: String

    init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}
