import Foundation
import Testing

import GRDB
import SwiftData

/// Scenario G — streaming write pressure.
///
/// The blueprint's design is buffer → coalesce → periodic snapshot → terminal
/// flush. The question is not which engine is faster; it is **which one can be held
/// to a predictable write schedule**, because that schedule is what the app has to
/// reason about when it decides how often to persist mid-stream.
///
/// So the shape here is deliberate:
///
/// - **assertions** cover properties that are stable and decidable — the persisted
///   total is correct, the write count actually collapsed, the terminal flush is what
///   survives a reopen, and a reader is not blocked while a writer commits
/// - **measurements** — wall time, per-write latency percentiles, file growth — are
///   printed, not asserted
///
/// Timing numbers asserted as thresholds are flaky on shared CI runners, and the
/// decision does not turn on them: if both engines are fast enough, being slower is
/// not a reason to reject one. Reporting them keeps the evidence available without
/// inventing a verdict from noise.
///
/// Flushed with `print` and a `[G]` prefix so the numbers are greppable in the CI log
/// rather than trapped inside an assertion that only speaks when it fails.
@Suite("Scenario G — streaming write pressure")
struct ScenarioGTests {

    /// Deltas per run, and the coalescing window the app would use.
    private static let deltaCount = 600
    private static let batchSize = 50

    private func report(_ engine: String, _ metric: String, _ value: String) {
        print("[G] \(engine) \(metric)=\(value)")
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let index = Int((p / 100.0) * Double(sorted.count - 1))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func summarise(_ engine: String, latencies: [Double], wall: TimeInterval, writes: Int, bytes: Int) {
        let sorted = latencies.sorted()
        report(engine, "writes", "\(writes)")
        report(engine, "wall_ms", String(format: "%.1f", wall * 1000))
        report(engine, "write_p50_ms", String(format: "%.2f", percentile(sorted, 50)))
        report(engine, "write_p95_ms", String(format: "%.2f", percentile(sorted, 95)))
        report(engine, "store_bytes", "\(bytes)")
    }

    // MARK: - GRDB

    @Test("G · GRDB — batched writes collapse, flush survives a reopen, readers keep working")
    func grdbWritePressure() throws {
        let url = try makeScratchPath(name: "grdb-g.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        var latencies: [Double] = []
        var writes = 0

        let started = Date()
        do {
            let queue = try DatabaseQueue(path: path)
            defer { try? queue.close() }

            try queue.write { db in
                try db.create(table: "delta") { t in
                    t.primaryKey("seq", .integer)
                    t.column("runID", .text).notNull()
                    t.column("text", .text).notNull()
                }
            }

            // Batched: the app coalesces deltas and writes them in one transaction.
            var batch: [Int] = []
            for seq in 1...Self.deltaCount {
                batch.append(seq)
                if batch.count == Self.batchSize {
                    let t0 = Date()
                    try queue.write { db in
                        for s in batch {
                            try db.execute(
                                sql: "INSERT INTO delta (seq, runID, text) VALUES (?, ?, ?)",
                                arguments: [s, "r1", "chunk-\(s)"]
                            )
                        }
                    }
                    latencies.append(Date().timeIntervalSince(t0) * 1000)
                    writes += 1
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        let wall = Date().timeIntervalSince(started)

        // --- assertion: the persisted total is right, and batching actually batched
        let (persisted, rows) = try grdbRead(path)
        #expect(
            persisted == Self.deltaCount,
            "every delta must be persisted; found \(persisted) of \(Self.deltaCount)"
        )
        #expect(
            writes <= (Self.deltaCount / Self.batchSize) + 2,
            """
            writes must collapse to roughly one per batch, not one per delta. \
            Observed \(writes) writes for \(Self.deltaCount) deltas at batch \(Self.batchSize).
            """
        )
        #expect(rows > 0, "the store must actually contain rows after the flush")

        summarise("GRDB", latencies: latencies, wall: wall, writes: writes, bytes: storeBytes(url))
    }

    @Test("G · GRDB — a reader is not blocked while a writer commits batches")
    func grdbReadersAreNotBlocked() throws {
        let url = try makeScratchPath(name: "grdb-g-reader.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        // A busy timeout, so contention shows up as *waiting* rather than as a
        // thrown error. Without it the measurement would be of GRDB's default
        // reaction to a locked database, not of whether a reader can proceed.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)

        let queue = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? queue.close() }
        try queue.write { db in
            try db.create(table: "delta") { t in
                t.primaryKey("seq", .integer)
                t.column("runID", .text).notNull()
            }
        }

        // Read from a second connection while the first is mid-batch. If reads had to
        // wait for the writer, the streaming UI would stutter every time a snapshot
        // lands — which is the thing the coalescing design exists to avoid.
        let reader = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? reader.close() }

        var readMilliseconds: [Double] = []
        for seq in 1...Self.deltaCount {
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO delta (seq, runID) VALUES (?, ?)",
                    arguments: [seq, "r1"]
                )
            }
            if seq % Self.batchSize == 0 {
                let t0 = Date()
                let count = try reader.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delta") ?? -1
                }
                readMilliseconds.append(Date().timeIntervalSince(t0) * 1000)
                #expect(count >= 0, "a concurrent read must return a result, not fail")
            }
        }

        #expect(
            readMilliseconds.count == Self.deltaCount / Self.batchSize,
            "every read must have completed; \(readMilliseconds.count) of \(Self.deltaCount / Self.batchSize)"
        )
        report("GRDB", "read_p95_ms", String(format: "%.2f", percentile(readMilliseconds.sorted(), 95)))
    }

    @Test("G · GRDB — the terminal flush is what survives a reopen")
    func grdbTerminalFlushIsDurable() throws {
        let url = try makeScratchPath(name: "grdb-g-durable.sqlite")
        let path = url.path()
        defer { cleanUp(url) }

        do {
            let queue = try DatabaseQueue(path: path)
            defer { try? queue.close() }
            try queue.write { db in
                try db.create(table: "snapshot") { t in
                    t.primaryKey("runID", .text)
                    t.column("throughSeq", .integer).notNull()
                }
            }
            // Partial writes first, as a stream would produce them.
            for seq in stride(from: Self.batchSize, through: Self.deltaCount - Self.batchSize, by: Self.batchSize) {
                try queue.write { db in
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO snapshot (runID, throughSeq) VALUES ('r1', ?)",
                        arguments: [seq]
                    )
                }
            }
            // Then the terminal flush.
            try queue.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO snapshot (runID, throughSeq) VALUES ('r1', ?)",
                    arguments: [Self.deltaCount]
                )
            }
        }

        // Reopen: the durable point must be the terminal flush, not some earlier
        // snapshot and not a value that never made it to disk.
        let survived = try grdbSnapshot(path)
        #expect(
            survived == Self.deltaCount,
            """
            the last durable snapshot must be the terminal flush. Read back \
            \(String(describing: survived)) instead of \(Self.deltaCount)
            """
        )
    }

    // MARK: - GRDB helpers

    private func grdbRead(_ path: String) throws -> (persisted: Int, rows: Int) {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.read { db in
            (
                persisted: try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM delta") ?? 0,
                rows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delta") ?? 0
            )
        }
    }

    private func grdbSnapshot(_ path: String) throws -> Int? {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT throughSeq FROM snapshot WHERE runID = 'r1'")
        }
    }

    // MARK: - SwiftData

    @Test("G · SwiftData — batched writes collapse, flush survives a reopen, readers keep working")
    @MainActor
    func swiftDataWritePressure() throws {
        let url = try makeScratchPath(name: "swiftdata-g.store")
        defer { cleanUp(url) }

        var latencies: [Double] = []
        var writes = 0

        let started = Date()
        do {
            let container = try ModelContainer(
                for: DeltaRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false

            var batch: [Int] = []
            for seq in 1...Self.deltaCount {
                batch.append(seq)
                if batch.count == Self.batchSize {
                    let t0 = Date()
                    for s in batch {
                        context.insert(DeltaRecord(seq: s, runID: "r1", text: "chunk-\(s)"))
                    }
                    try context.save()
                    latencies.append(Date().timeIntervalSince(t0) * 1000)
                    writes += 1
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        let wall = Date().timeIntervalSince(started)

        let (persisted, rows) = try swiftDataRead(url)
        #expect(
            persisted == Self.deltaCount,
            "every delta must be persisted; found \(persisted) of \(Self.deltaCount)"
        )
        #expect(
            writes <= (Self.deltaCount / Self.batchSize) + 2,
            """
            writes must collapse to roughly one per batch, not one per delta. \
            Observed \(writes) writes for \(Self.deltaCount) deltas at batch \(Self.batchSize).
            """
        )
        #expect(rows > 0, "the store must actually contain rows after the flush")

        summarise("SwiftData", latencies: latencies, wall: wall, writes: writes, bytes: storeBytes(url))
    }

    @Test("G · SwiftData — a reader is not blocked while a writer commits batches")
    @MainActor
    func swiftDataReadersAreNotBlocked() throws {
        let url = try makeScratchPath(name: "swiftdata-g-reader.store")
        defer { cleanUp(url) }

        let container = try ModelContainer(
            for: DeltaRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let writer = ModelContext(container)
        writer.autosaveEnabled = false
        // A second context is the natural analogue of SwiftData's reader: the UI
        // would read on its own context while a background write commits.
        let reader = ModelContext(container)

        var readMilliseconds: [Double] = []
        for seq in 1...Self.deltaCount {
            writer.insert(DeltaRecord(seq: seq, runID: "r1", text: ""))
            if seq % Self.batchSize == 0 {
                try writer.save()
                let t0 = Date()
                let count = try reader.fetchCount(FetchDescriptor<DeltaRecord>())
                readMilliseconds.append(Date().timeIntervalSince(t0) * 1000)
                #expect(count >= 0, "a concurrent read must return a result, not fail")
            }
        }

        #expect(
            readMilliseconds.count == Self.deltaCount / Self.batchSize,
            "every read must have completed; \(readMilliseconds.count) of \(Self.deltaCount / Self.batchSize)"
        )
        report("SwiftData", "read_p95_ms", String(format: "%.2f", percentile(readMilliseconds.sorted(), 95)))
    }

    @Test("G · SwiftData — the terminal flush is what survives a reopen")
    @MainActor
    func swiftDataTerminalFlushIsDurable() throws {
        let url = try makeScratchPath(name: "swiftdata-g-durable.store")
        defer { cleanUp(url) }

        do {
            let container = try ModelContainer(
                for: SnapshotRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false

            for seq in stride(from: Self.batchSize, through: Self.deltaCount - Self.batchSize, by: Self.batchSize) {
                for existing in try context.fetch(FetchDescriptor<SnapshotRecord>()) {
                    context.delete(existing)
                }
                context.insert(SnapshotRecord(runID: "r1", throughSeq: seq))
                try context.save()
            }

            for existing in try context.fetch(FetchDescriptor<SnapshotRecord>()) {
                context.delete(existing)
            }
            context.insert(SnapshotRecord(runID: "r1", throughSeq: Self.deltaCount))
            try context.save()
        }

        let survived = try swiftDataSnapshot(url)
        #expect(
            survived == Self.deltaCount,
            """
            the last durable snapshot must be the terminal flush. Read back \
            \(String(describing: survived)) instead of \(Self.deltaCount)
            """
        )
    }

    // MARK: - SwiftData helpers

    @MainActor
    private func swiftDataRead(_ url: URL) throws -> (persisted: Int, rows: Int) {
        let container = try ModelContainer(
            for: DeltaRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<DeltaRecord>())
        return (persisted: rows.map(\.seq).max() ?? 0, rows: rows.count)
    }

    @MainActor
    private func swiftDataSnapshot(_ url: URL) throws -> Int? {
        let container = try ModelContainer(
            for: SnapshotRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<SnapshotRecord>()).first?.throughSeq
    }
}

/// Shared with the GRDB half so both engines are measured on the same directory
/// accounting.
private func storeBytes(_ url: URL) -> Int {
    let directory = url.deletingLastPathComponent()
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey]
    )) ?? []
    return contents.reduce(0) { total, file in
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return total + size
    }
}

// MARK: - Probe models

/// Throwaway models for scenario G. Not drafts of product entities.
///
/// `seq` is an integer so the "persisted through sequence N" question has a
/// single-column answer, which is what a snapshot pointer looks like in practice.
@Model
final class DeltaRecord {
    var seq: Int
    var runID: String
    var text: String

    init(seq: Int, runID: String, text: String) {
        self.seq = seq
        self.runID = runID
        self.text = text
    }
}

@Model
final class SnapshotRecord {
    var runID: String
    var throughSeq: Int

    init(runID: String, throughSeq: Int) {
        self.runID = runID
        self.throughSeq = throughSeq
    }
}
