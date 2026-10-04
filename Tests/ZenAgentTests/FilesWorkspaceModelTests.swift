import Foundation
import Testing
@testable import ZenAgent

@Suite("Files Workspace import ownership")
@MainActor
struct FilesWorkspaceModelTests {
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
