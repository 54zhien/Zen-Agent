import Foundation
import GRDB

/// Owns the database connection and the migrations that bring it up to date.
///
/// **The only place a GRDB connection is created**, and — together with the rest of
/// `App/Persistence/` — the only place that imports GRDB. That boundary is enforced
/// by a CI check rather than by good intentions: `App/Persistence` is the sole
/// directory allowed to import GRDB, so a stray `DatabaseQueue` in a view model fails
/// the build rather than quietly becoming a second route to the data.
///
/// Note what this type does **not** do. It is not a database-abstraction layer, and
/// nothing here exists to keep the option of swapping GRDB out. ADR-0001 is accepted;
/// the point of the spike was to stop hedging and use the chosen engine properly. The
/// boundary exists so that transaction rules live in one place and the type can be
/// tested in isolation — not so the engine can be replaced.
final class ZenDatabase {
    private let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Opens (or creates) a store at `path` and brings its schema up to date.
    ///
    /// WAL is on because the app reads while it writes: the conversation is on screen
    /// and updating while a run is streaming into it. The Stage 0 spike measured that
    /// a reader is not blocked by a committing writer — that result is what this
    /// configuration is for.
    static func open(at path: String) throws -> ZenDatabase {
        try open(at: path, migrator: Migrations.makeMigrator())
    }

    /// Opens with a caller-supplied migrator. Used by the migration tests, which
    /// compose `Migrations.registerV1` with a v2 of their own.
    static func open(at path: String, migrator: DatabaseMigrator) throws -> ZenDatabase {
        var configuration = Configuration()
        configuration.journalMode = .wal
        // Contention surfaces as waiting rather than as a thrown "database is locked",
        // which is what a reader should experience while a writer is committing.
        configuration.busyMode = .timeout(5)

        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try migrator.migrate(queue)
        return ZenDatabase(dbQueue: queue)
    }

    /// A throwaway store that never touches disk. For tests.
    static func inMemory() throws -> ZenDatabase {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)
        return ZenDatabase(dbQueue: queue)
    }

    /// Read-only access. Concurrent reads are the normal case.
    func read<T>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.read(body)
    }

    /// Read-write access. Everything in `body` runs in one transaction: it commits
    /// together or rolls back together.
    func write<T>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.write(body)
    }
}
