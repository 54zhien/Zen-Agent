import Foundation
import Testing

@testable import ZenAgent

@Suite("Files Workspace reference safety")
struct FilesWorkspaceTests {
    @Test("a redirected cache namespace cannot receive or delete native presentation bytes")
    func cacheSymlinkCannotRedirectCopyOrCleanup() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let outside = root.appendingPathComponent("OtherData", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("retained.txt")
        try Data("outside cache".utf8).write(to: sentinel)
        let files = ManagedFileStore(applicationSupportRoot: root,
            protectionRequirement: .bestEffort, presentationCacheRoot: cache)
        let item = try files.ingest(data: Data("managed".utf8), displayName: "managed.txt", in: store)
        try FileManager.default.createSymbolicLink(at: files.presentationCacheRoot, withDestinationURL: outside)
        do {
            _ = try files.makePresentationCopy(for: attachment(item), in: store)
            Issue.record("a symlink redirected a native presentation")
        } catch let error as ManagedFileStoreError { #expect(error == .invalidManagedPath) }
        do {
            _ = try files.clearPresentationCache()
            Issue.record("a symlink redirected cache cleanup")
        } catch let error as ManagedFileStoreError { #expect(error == .invalidManagedPath) }
        #expect(try Data(contentsOf: sentinel) == Data("outside cache".utf8))
        #expect(try store.fileAssetVersion(id: item.versionID) != nil)
    }

    @Test("missing or corrupt preview bytes report failure without deleting catalog history",
          arguments: [true, false])
    func damagedPresentationKeepsItsAssetAndVersion(corrupt: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let item = try files.ingest(data: Data("retained original".utf8), displayName: "retained.txt", in: store)
        let blob = try files.blobURL(forFingerprint: item.fingerprint)
        if corrupt { try Data("different bytes".utf8).write(to: blob) }
        else { try FileManager.default.removeItem(at: blob) }
        do {
            _ = try files.makePresentationCopy(for: attachment(item), in: store)
            Issue.record("an unavailable version must not become a native preview/export")
        } catch let error as ManagedFileStoreError {
            #expect(error == (corrupt ? .corruptBlob(item.fingerprint) : .missingBlob(item.fingerprint)))
        }
        #expect(try store.fileAsset(id: item.assetID)?.currentVersionID == item.versionID)
        #expect(try store.fileAssetVersion(id: item.versionID)?.contentFingerprint == item.fingerprint)
        #expect(try store.fileWorkspacePage(limit: 10, after: nil).items.map(\.id) == [item.assetID])
    }

    @MainActor
    @Test("owned worker cancellation prevents asset and version commit")
    func cancelledWorkerDoesNotCommitAssetAndVersion() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let entered = AsyncStream<Void>.makeStream()
        let attempted = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = Task.detached {
            try store.database.write { _ in
                entered.continuation.yield(())
                release.wait()
            }
        }
        var writerEvents = entered.stream.makeAsyncIterator()
        _ = try #require(await writerEvents.next())
        let signal = FileAssetWriteCancellationReceipt()
        let asset = FileAssetRecord(id: "cancelled-asset", displayName: "cancelled.txt",
            currentVersionID: "cancelled-version", origin: .imported,
            createdAt: Fixtures.epoch, updatedAt: Fixtures.epoch)
        let version = FileAssetVersionRecord(id: "cancelled-version", assetID: asset.id,
            contentFingerprint: ManagedFileStore.fingerprint(of: Data("cancelled".utf8)),
            byteCount: 9, mediaType: "text/plain", createdAt: Fixtures.epoch)
        let write = Task.detached {
            // This reports a caller attempt, not GRDB queue admission. The
            // placement of the check inside the transaction is reviewed too.
            attempted.continuation.yield(())
            try store.createFileAsset(asset, initialVersion: version,
                                      checkCancellation: { try signal.check() })
        }
        var attempts = attempted.stream.makeAsyncIterator()
        _ = try #require(await attempts.next())
        signal.cancel()
        release.signal()
        try await blocker.value
        do {
            try await write.value
            Issue.record("a cancelled queued import committed its asset")
        } catch is CancellationError {}
        #expect(signal.checkedOffMainThread)
        #expect(try store.fileAsset(id: asset.id) == nil)
        #expect(try store.fileAssetVersion(id: version.id) == nil)
    }

    @Test("catalog pages contain bounded metadata with a stable keyset cursor")
    func catalogPaginationDoesNotDuplicateOrLoadPayloads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        var expected = Set<String>()
        for index in 0..<5 {
            let item = try files.ingest(data: Data("same bytes".utf8),
                displayName: "file-\(index).txt", mediaType: "text/plain", in: store)
            expected.insert(item.assetID)
        }
        var ids: [String] = []
        var cursor: FileWorkspaceCursor?
        for _ in 0..<4 {
            let page = try store.fileWorkspacePage(limit: 2, after: cursor)
            #expect(page.items.count <= 2)
            #expect(page.items.allSatisfy { $0.byteCount == 10 && $0.mediaType == "text/plain" })
            ids.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        #expect(Set(ids) == expected)
        #expect(ids.count == expected.count)
        #expect(cursor == nil)
    }

    @Test("native presentation retains verified immutable bytes after catalog removal")
    func presentationCopyOutlivesItsCatalogAsset() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let bytes = Data("immutable preview and exported bytes".utf8)
        let item = try files.ingest(data: bytes, displayName: "immutable.txt", in: store)
        let presentation = try files.makePresentationCopy(for: attachment(item), in: store)
        #expect(presentation.url.lastPathComponent == "immutable.txt")
        #expect(try Data(contentsOf: presentation.url) == bytes)
        #expect(try files.removeUnreferencedAsset(id: item.assetID, in: store, protectedAssetIDs: []))
        #expect(try store.fileAsset(id: item.assetID) == nil)
        #expect(try Data(contentsOf: presentation.url) == bytes)
        _ = try files.clearPresentationCache()
        #expect(try Data(contentsOf: presentation.url) == bytes,
                "cache cleanup must preserve the copy owned by a displayed preview/export")
        let otherInstance = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        _ = try otherInstance.clearPresentationCache()
        #expect(try Data(contentsOf: presentation.url) == bytes,
                "a second file-store instance must honor the same active presentation lease")
    }

    @Test("removing an unreferenced asset preserves another asset sharing its bytes")
    func sharedBytesSurviveOneRemoval() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let bytes = Data("shared immutable bytes".utf8)
        let first = try files.ingest(data: bytes, displayName: "first.txt", in: store)
        let second = try files.ingest(data: bytes, displayName: "second.txt", in: store)

        let removed = try files.removeUnreferencedAsset(id: first.assetID, in: store,
                                                      protectedAssetIDs: [])
        #expect(removed)
        #expect(try store.fileAsset(id: first.assetID) == nil)
        #expect(try store.fileAssetVersion(id: first.versionID) == nil)
        let survivingURL = try files.verifiedBlobURL(for: attachment(second), in: store)
        #expect(try Data(contentsOf: survivingURL) == bytes)
    }

    @Test("a durable old version prevents removing its asset after current version advances")
    func historicalAttachmentProtectsEveryVersion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let oldBytes = Data("historical version".utf8)
        let original = try files.ingest(data: oldBytes, displayName: "history.txt", in: store)
        var send = Fixtures.send(messageID: "file-message", runID: "file-run")
        send.attachments = [MessageAttachmentRecord(id: "file-link", messageID: "file-message",
            assetID: original.assetID, versionID: original.versionID, sequence: 0)]
        try store.commitUserTurnAndCreateParentRun(send)
        let newer = try files.ingest(data: Data("new current version".utf8),
                                     displayName: "new.txt", in: store)
        try store.advanceFileAsset(id: original.assetID, to: FileAssetVersionRecord(
            id: "advanced-version", assetID: original.assetID,
            contentFingerprint: newer.fingerprint, byteCount: newer.byteCount,
            mediaType: newer.mediaType, createdAt: Fixtures.epoch.addingTimeInterval(1)))

        let removed = try files.removeUnreferencedAsset(id: original.assetID, in: store,
                                                      protectedAssetIDs: [])
        #expect(!removed)
        #expect(try store.fileAsset(id: original.assetID)?.currentVersionID == "advanced-version")
        let oldURL = try files.verifiedBlobURL(for: attachment(original), in: store)
        #expect(try Data(contentsOf: oldURL) == oldBytes)
        #expect(try store.attachments(forMessage: "file-message").first?.versionID == original.versionID)
    }

    @Test("a warm draft or pending send lease prevents metadata and byte removal")
    func transientReferenceProtectionIsHonored() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let bytes = Data("awaiting acceptance".utf8)
        let item = try files.ingest(data: bytes, displayName: "pending.txt", in: store)

        let refused = try files.removeUnreferencedAsset(id: item.assetID, in: store,
                                                      protectedAssetIDs: [item.assetID])
        #expect(!refused)
        let url = try files.verifiedBlobURL(for: attachment(item), in: store)
        #expect(try Data(contentsOf: url) == bytes)
        let removed = try files.removeUnreferencedAsset(id: item.assetID, in: store,
                                                      protectedAssetIDs: [])
        #expect(removed)
        #expect(try store.fileAsset(id: item.assetID) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("workspace-files-\(UUID())",
                                                                    isDirectory: true)
    }

    private func attachment(_ descriptor: ManagedFileDescriptor) -> SendAttachment {
        SendAttachment(assetID: descriptor.assetID, versionID: descriptor.versionID,
                       fingerprint: descriptor.fingerprint, kind: .file,
                       displayName: descriptor.displayName)
    }
}

private final class FileAssetWriteCancellationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var offMain = false
    var checkedOffMainThread: Bool { lock.lock(); defer { lock.unlock() }; return offMain }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        offMain = offMain || !Thread.isMainThread
        let cancelled = cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}
