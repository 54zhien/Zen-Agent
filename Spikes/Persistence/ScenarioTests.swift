import Foundation
import Testing

import GRDB
import SwiftData

/// Scenario C — the crash window.
///
/// The blueprint requires that after a crash, recovery can tell *"prepared but
/// never dispatched"* from *"possibly dispatched"*. Only the first may be
/// re-executed; the second must become `indeterminate` and never auto-retry.
///
/// The engine's job here is narrow but load-bearing: a small state marker must be
/// **durably committed**, and the two states must stay **distinguishable** once the
/// writer is gone. If `dispatching` reads back as `prepared`, recovery re-dispatches
/// a write that may already have reached the outside world — exactly the failure
/// the `indeterminate` concept exists to prevent.
///
/// "The process died" is simulated by releasing the writer entirely and opening a
/// **fresh, independent handle over the same file**. That is what a crash leaves
/// behind: a file, and nothing else. Reading back through the original handle would
/// prove nothing, because it could be serving the write from memory.
///
/// The ordering being asserted is the one the design depends on — `dispatching` is
/// committed **before** the external call is made. That is what makes the uncertain
/// window *possibly dispatched* rather than *unknown*, and it is why the safe
/// failure mode is "refuse to retry" rather than "retry and hope".
@Suite("Scenario C — crash window")
struct ScenarioCTests {

    /// The ToolCall phases that matter for the crash window. Deliberately just the
    /// ones C is about; `succeeded`/`failed` are terminal and not a recovery risk.
    enum Phase: String {
        case prepared
        case dispatching
    }

    // MARK: - GRDB

    @Test("C · GRDB — prepared and dispatching survive a reopen, still distinguishable")
    func grdbCrashWindow() throws {
        let url = try makeScratchPath(name: "grdb-tools.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        // Prepared is committed before anything leaves the process.
        do {
            let pool = try DatabasePool(path: path)
            try pool.write { db in
                try db.create(table: "toolCall") { t in
                    t.primaryKey("id", .text)
                    t.column("phase", .text).notNull()
                    t.column("attempt", .integer).notNull()
                }
                try db.execute(
                    sql: "INSERT INTO toolCall (id, phase, attempt) VALUES (?, ?, ?)",
                    arguments: ["tc1", Phase.prepared.rawValue, 1]
                )
            }
        }
        let afterPrepared = try grdbPhase(path)
        #expect(
            afterPrepared == Phase.prepared.rawValue,
            "prepared must be durable after the writer is gone; read back \(describe(afterPrepared))"
        )

        // The writer is gone. This is the crash. Recovery now commits the marker
        // that says "an external call is about to be attempted" — still before it
        // is attempted.
        do {
            let pool = try DatabasePool(path: path)
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE toolCall SET phase = ? WHERE id = ?",
                    arguments: [Phase.dispatching.rawValue, "tc1"]
                )
            }
        }
        let recovered = try grdbPhase(path)

        #expect(
            recovered == Phase.dispatching.rawValue,
            """
            recovery must see \(Phase.dispatching.rawValue), not \(describe(recovered)). \
            Reading back \(describe(recovered)) means the two states collapsed and \
            recovery would re-dispatch a call that may already have happened.
            """
        )
    }

    // MARK: - SwiftData

    @Test("C · SwiftData — prepared and dispatching survive a reopen, still distinguishable")
    @MainActor
    func swiftDataCrashWindow() throws {
        let url = try makeScratchPath(name: "swiftdata-tools.store")
        defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: ToolCallRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.insert(ToolCallRecord(id: "tc1", phase: Phase.prepared.rawValue, attempt: 1))
            try context.save()
        }
        let afterPrepared = try swiftDataPhase(url)
        #expect(
            afterPrepared == Phase.prepared.rawValue,
            "prepared must be durable after the writer is gone; read back \(describe(afterPrepared))"
        )

        do {
            let container = try ModelContainer(
                for: ToolCallRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            guard let existing = try context.fetch(FetchDescriptor<ToolCallRecord>()).first else {
                Issue.record("expected the tool call to survive the reopen, found none")
                return
            }
            existing.phase = Phase.dispatching.rawValue
            try context.save()
        }
        let recovered = try swiftDataPhase(url)

        #expect(
            recovered == Phase.dispatching.rawValue,
            """
            recovery must see \(Phase.dispatching.rawValue), not \(describe(recovered)). \
            Reading back \(describe(recovered)) means the two states collapsed and \
            recovery would re-dispatch a call that may already have happened.
            """
        )
    }

    // MARK: - Helpers

    private func describe(_ phase: String?) -> String {
        phase.map { "\"\($0)\"" } ?? "nothing"
    }

    private func makeScratchPath(name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "zen-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func grdbPhase(_ path: String) throws -> String? {
        let pool = try DatabasePool(path: path)
        return try pool.read { db in
            try String.fetchOne(db, sql: "SELECT phase FROM toolCall WHERE id = 'tc1'")
        }
    }

    @MainActor
    private func swiftDataPhase(_ url: URL) throws -> String? {
        let container = try ModelContainer(
            for: ToolCallRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ToolCallRecord>()).first?.phase
    }
}

/// Throwaway model for scenario C. Not a draft of a product entity.
///
/// `phase` is stored as a raw string rather than an enum so the probe measures the
/// engine's durability, not its Codable handling.
@Model
final class ToolCallRecord {
    var id: String
    var phase: String
    var attempt: Int

    init(id: String, phase: String, attempt: Int) {
        self.id = id
        self.phase = phase
        self.attempt = attempt
    }
}
