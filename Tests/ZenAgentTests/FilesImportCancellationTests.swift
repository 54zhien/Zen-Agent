import Foundation
import Testing
@testable import ZenAgent

@Suite("Files import cancellation")
@MainActor
struct FilesImportCancellationTests {
    @Test("cancellation after copying still prevents verification and metadata publication")
    func cancellationAfterCopyDoesNotPublishAnAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "files-cancel-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let cancellation = FileImportCancellationReceipt()
        let start = AsyncStream<Void>.makeStream()
        let files = ManagedFileStore(applicationSupportRoot: root,
            protectionRequirement: .bestEffort, temporaryFileObserver: { _, phase in
                guard phase == .protectedAfterWrite else { return }
                cancellation.cancelAfterCopy()
            })
        let bytes = Data(repeating: 0x35, count: 192 * 1024)
        let importTask = Task.detached {
            var starts = start.stream.makeAsyncIterator()
            guard await starts.next() != nil else { throw CancellationError() }
            return try files.ingest(data: bytes, displayName: "cancelled.txt", in: store)
        }
        cancellation.bind(importTask)
        start.continuation.yield(())
        start.continuation.finish()
        var cancelled = false
        do { _ = try await importTask.value }
        catch is CancellationError { cancelled = true }
        #expect(cancellation.didCancel)
        #expect(cancelled)
        #expect(try store.fileAssetVersionFingerprints().isEmpty)
        let blob = try files.blobURL(forFingerprint: ManagedFileStore.fingerprint(of: bytes))
        #expect(!FileManager.default.fileExists(atPath: blob.path))
    }
}

private final class FileImportCancellationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ManagedFileDescriptor, Error>?
    private var cancelled = false
    var didCancel: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func bind(_ task: Task<ManagedFileDescriptor, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func cancelAfterCopy() {
        lock.lock()
        let task = self.task
        self.task = nil
        cancelled = task != nil
        lock.unlock()
        // Cancel the actual import Task at the existing copy completion hook.
        // Do not park the process-wide file lock waiting for MainActor control.
        task?.cancel()
    }
}
