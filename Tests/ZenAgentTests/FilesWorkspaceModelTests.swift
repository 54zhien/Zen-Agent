import Foundation
import Testing
@testable import ZenAgent

@Suite("Files Workspace import ownership")
@MainActor
struct FilesWorkspaceModelTests {
    @Test("post-commit byte cleanup failure refreshes the catalog and reports the committed removal")
    func committedRemovalCannotLeaveAStaleCatalogRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RefusingBlobRemovalFileManager()
        let files = ManagedFileStore(applicationSupportRoot: root, fileManager: manager,
            protectionRequirement: .bestEffort)
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let bytes = Data("recoverable orphan bytes".utf8)
        let descriptor = try await Task.detached {
            try files.ingest(data: bytes, displayName: "cleanup.txt", in: store)
        }.value
        let retainedBytes = Data("still referenced version bytes".utf8)
        let retained = try await Task.detached {
            try files.ingest(data: retainedBytes, displayName: "retained.txt", in: store)
        }.value
        let blob = try files.blobURL(forFingerprint: descriptor.fingerprint)
        let model = FilesWorkspaceModel(store: store, files: files, sessions: ConversationSessionStore())
        await model.refresh()
        #expect(Set(model.items.map(\.id)) == [descriptor.assetID, retained.assetID])
        manager.refuseRemoval(of: blob)

        await model.removeAsset(id: descriptor.assetID)

        #expect(manager.didRefuseRemoval)
        #expect(try store.fileAsset(id: descriptor.assetID) == nil)
        #expect(try store.fileAssetVersion(id: descriptor.versionID) == nil)
        #expect(try Data(contentsOf: blob) == bytes)
        #expect(model.items.map(\.id) == [retained.assetID])
        #expect(model.errorMessage?.contains("已从目录移除") == true)
        #expect(model.cleanupPending)
        #expect(!model.isWorking)
        manager.refuseRemoval(of: nil)
        await model.retryOrphanCleanup()
        #expect(!model.cleanupPending && model.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        let retainedBlob = try files.blobURL(forFingerprint: retained.fingerprint)
        #expect(try store.fileAssetVersion(id: retained.versionID) != nil)
        #expect(try Data(contentsOf: retainedBlob) == retainedBytes)
    }

    @Test("the actual catalog import copies off the presentation actor")
    func importPublishesManagedBytesWithoutMainThreadCopying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let bytes = Data("actual catalog import".utf8)
        try bytes.write(to: source)
        let threads = FileImportThreadReceipt()
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort,
            temporaryFileObserver: { _, _ in threads.record(isMainThread: Thread.isMainThread) })
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let model = FilesWorkspaceModel(store: store, files: files, sessions: ConversationSessionStore())
        await model.importFile(at: source)
        #expect(threads.didCopy && !threads.usedMainThread)
        let item = try #require(model.items.first)
        #expect(item.displayName == "source.txt" && item.byteCount == Int64(bytes.count))
        let version = try #require(try store.fileAssetVersion(id: item.versionID))
        let attachment = SendAttachment(assetID: item.id,
            versionID: item.versionID, fingerprint: version.contentFingerprint, kind: .file,
            displayName: item.displayName)
        // A parallel held-import test owns the process-wide file lock while
        // awaiting cancellation on MainActor. Verification must not block it.
        let actual = try await Task.detached {
            try files.withVerifiedBlob(for: attachment, in: store) { try Data(contentsOf: $0) }
        }.value
        #expect(actual == bytes)
    }

    @Test("closing during a real held import cancels its bytes and metadata publication")
    func closeCancelsTheOwnedWorkerAndWaitsForItsDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-model-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("cancel.txt")
        let bytes = Data(repeating: 0x43, count: 192 * 1024)
        try bytes.write(to: source)
        let copied = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort,
            temporaryFileObserver: { _, phase in
                guard phase == .protectedAfterWrite else { return }
                copied.continuation.yield(())
                release.wait()
            })
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let model = FilesWorkspaceModel(store: store, files: files, sessions: ConversationSessionStore())
        let task = Task { await model.importFile(at: source) }
        var events = copied.stream.makeAsyncIterator()
        _ = try #require(await events.next())
        model.invalidate()
        #expect(model.isWorking, "the owned writer has not exited yet")
        release.signal()
        await task.value
        #expect(!model.isWorking && model.items.isEmpty)
        #expect(try store.fileAssetVersionFingerprints().isEmpty)
        let blob = try files.blobURL(forFingerprint: ManagedFileStore.fingerprint(of: bytes))
        #expect(!FileManager.default.fileExists(atPath: blob.path))
    }
}

private final class RefusingBlobRemovalFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var refusedPath: String?
    private var refused = false
    var didRefuseRemoval: Bool { lock.lock(); defer { lock.unlock() }; return refused }
    func refuseRemoval(of url: URL?) {
        lock.lock(); defer { lock.unlock() }
        refusedPath = url?.path
    }
    override func removeItem(at url: URL) throws {
        lock.lock()
        let shouldRefuse = refusedPath == url.path
        if shouldRefuse { refused = true }
        lock.unlock()
        if shouldRefuse {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.removeItem(at: url)
    }
}

private final class FileImportThreadReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var copied = false
    private var mainThread = false
    var didCopy: Bool { lock.lock(); defer { lock.unlock() }; return copied }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func record(isMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        copied = true; mainThread = mainThread || isMainThread
    }
}
