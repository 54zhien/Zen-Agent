import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Managed file store")
struct ManagedFileStoreTests {
    @Test("ingestPublishesContentAddressedBlobUnderApplicationSupport")
    func ingestPublishesContentAddressedBlobUnderApplicationSupport() throws {
        let actualApplicationSupport = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)
        let productionStore = try ManagedFileStore.applicationDefault()
        #expect(productionStore.rootURL == actualApplicationSupport
            .appendingPathComponent("ZenAgent", isDirectory: true)
            .appendingPathComponent("FileAssets", isDirectory: true)
            .standardizedFileURL)

        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let observations = TemporaryProtectionObservations()
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            temporaryFileObserver: { url, phase in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                observations.append(
                    phase: phase,
                    protection: attributes?[.protectionKey] as? FileProtectionType
                )
            }
        )

        let bytes = Data("protected attachment bytes".utf8)
        let descriptor = try managedFiles.ingest(
            data: bytes,
            displayName: "manual.pdf",
            in: store
        )
        let digest = String(descriptor.fingerprint.dropFirst("sha256:".count))
        let blob = try managedFiles.blobURL(forFingerprint: descriptor.fingerprint)
        let expectedBlob = managedFiles.rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: false)

        #expect(managedFiles.rootURL.deletingLastPathComponent().lastPathComponent == "ZenAgent")
        #expect(blob == expectedBlob)
        #expect(try Data(contentsOf: blob) == bytes)

        let protectedDirectories = [
            managedFiles.rootURL.deletingLastPathComponent(),
            managedFiles.rootURL,
            managedFiles.rootURL.appendingPathComponent("blobs", isDirectory: true),
            managedFiles.rootURL
                .appendingPathComponent("blobs", isDirectory: true)
                .appendingPathComponent("sha256", isDirectory: true),
            blob.deletingLastPathComponent(),
        ]
        for directory in protectedDirectories {
            #expect(try protection(of: directory) == .completeUntilFirstUserAuthentication)
        }
        #expect(try protection(of: blob) == .completeUntilFirstUserAuthentication)
        // This checks the exclusion attribute only; it does not assert that a backup ran.
        let backupValues = try blob.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backupValues.isExcludedFromBackup != true)

        let temporarySamples = observations.all
        #expect(temporarySamples.count == 2)
        #expect(temporarySamples.allSatisfy {
            $0.protection == .completeUntilFirstUserAuthentication
        })
        #expect(temporarySamples.contains { $0.phase == .protectedBeforeWrite })
        #expect(temporarySamples.contains { $0.phase == .protectedAfterWrite })
    }

    @Test("sameBytesShareOneBlobButKeepDistinctAssetIdentities")
    func sameBytesShareOneBlobButKeepDistinctAssetIdentities() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let bytes = Data("same bytes".utf8)

        let first = try managedFiles.ingest(data: bytes, displayName: "first.txt", in: store)
        let second = try managedFiles.ingest(data: bytes, displayName: "second.txt", in: store)

        #expect(first.fingerprint == second.fingerprint)
        #expect(first.assetID != second.assetID)
        #expect(first.versionID != second.versionID)
        #expect(try managedFiles.blobURL(forFingerprint: first.fingerprint)
            == managedFiles.blobURL(forFingerprint: second.fingerprint))
        #expect(try store.fileAssetVersionFingerprints() == [first.fingerprint])
        #expect(try countRows(in: store, table: "fileAsset") == 2)
        #expect(try countRows(in: store, table: "fileAssetVersion") == 2)
    }

    @Test("ingestFailureLeavesNoBlobAndNoDatabaseRow")
    func ingestFailureLeavesNoBlobAndNoDatabaseRow() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let missingSource = supportRoot.appendingPathComponent("missing-source.bin")

        var failure: Error?
        do {
            _ = try managedFiles.ingest(fileAt: missingSource, displayName: "missing.bin", in: store)
        } catch {
            failure = error
        }

        #expect(failure != nil)
        #expect(try store.fileAssetVersionFingerprints().isEmpty)
        #expect(try managedFiles.unreferencedBlobDigests(in: store).isEmpty)
        let shaRoot = managedFiles.rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        let files = FileManager.default.fileExists(atPath: shaRoot.path)
            ? try FileManager.default.contentsOfDirectory(atPath: shaRoot.path)
            : []
        #expect(files.isEmpty)
    }

    @Test("existingBlobIsVerifiedNotOverwritten")
    func existingBlobIsVerifiedNotOverwritten() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let bytes = Data("immutable original".utf8)
        let first = try managedFiles.ingest(data: bytes, displayName: "original.txt", in: store)
        let blob = try managedFiles.blobURL(forFingerprint: first.fingerprint)
        let reused = try managedFiles.ingest(data: bytes, displayName: "copy.txt", in: store)
        #expect(reused.fingerprint == first.fingerprint)
        #expect(try Data(contentsOf: blob) == bytes)

        let sameSizeCorruption = Data("IMMUTABLE ORIGINAL".utf8)
        #expect(sameSizeCorruption.count == bytes.count)
        try sameSizeCorruption.write(to: blob)
        var failure: Error?
        do {
            _ = try managedFiles.ingest(data: bytes, displayName: "original.txt", in: store)
        } catch {
            failure = error
        }
        #expect(failure != nil)
        #expect(try Data(contentsOf: blob) == sameSizeCorruption)

        let differentSizeCorruption = Data("different bytes".utf8)
        try differentSizeCorruption.write(to: blob)
        failure = nil
        do {
            _ = try managedFiles.ingest(data: bytes, displayName: "original.txt", in: store)
        } catch {
            failure = error
        }
        #expect(failure != nil)
        #expect(try Data(contentsOf: blob) == differentSizeCorruption)
        #expect(try store.fileAssetVersionFingerprints() == [first.fingerprint])
    }

    @Test("blobPathNeverDerivesFromDisplayName")
    func blobPathNeverDerivesFromDisplayName() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let bytes = Data("display name is not a path".utf8)
        let names = ["../escape.txt", "/absolute/path.txt", "\0"]
        var paths: [URL] = []

        for name in names {
            let descriptor = try managedFiles.ingest(data: bytes, displayName: name, in: store)
            paths.append(try managedFiles.blobURL(forFingerprint: descriptor.fingerprint))
        }

        #expect(paths.count == names.count)
        #expect(paths.allSatisfy { $0 == paths[0] })
        #expect(paths[0].deletingLastPathComponent().lastPathComponent
            == String(ManagedFileStore.fingerprint(of: bytes).dropFirst("sha256:".count)))
        #expect(paths[0].path.hasPrefix(managedFiles.rootURL.path))
    }

    @Test("unreferencedBlobsAreRemovedButSharedBlobsAreNot")
    func unreferencedBlobsAreRemovedButSharedBlobsAreNot() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let sharedBytes = Data("shared".utf8)
        let first = try managedFiles.ingest(data: sharedBytes, displayName: "one.txt", in: store)
        _ = try managedFiles.ingest(data: sharedBytes, displayName: "two.txt", in: store)

        let orphanBytes = Data("orphan".utf8)
        let orphanFingerprint = ManagedFileStore.fingerprint(of: orphanBytes)
        let orphanURL = try managedFiles.blobURL(forFingerprint: orphanFingerprint)
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try orphanBytes.write(to: orphanURL)

        #expect(try managedFiles.unreferencedBlobDigests(in: store) == [orphanFingerprint])
        #expect(try managedFiles.removeUnreferencedBlobs(in: store) == [orphanFingerprint])
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(
            atPath: try managedFiles.blobURL(forFingerprint: first.fingerprint).path
        ))
        #expect(try store.fileAssetVersionFingerprints() == [first.fingerprint])
    }

    @Test("missingOrCorruptReferencedBlobFailsClosed")
    func missingOrCorruptReferencedBlobFailsClosed() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let missing = try managedFiles.ingest(
            data: Data("missing later".utf8),
            displayName: "missing.txt",
            in: store
        )
        let missingAttachment = sendAttachment(for: missing)
        try FileManager.default.removeItem(at: managedFiles.blobURL(forFingerprint: missing.fingerprint))

        var missingFailure: Error?
        do {
            _ = try managedFiles.loadVerifiedBlob(for: missingAttachment, in: store)
        } catch {
            missingFailure = error
        }
        #expect(missingFailure != nil)

        let corrupt = try managedFiles.ingest(
            data: Data("corrupt later".utf8),
            displayName: "corrupt.txt",
            in: store
        )
        let corruptURL = try managedFiles.blobURL(forFingerprint: corrupt.fingerprint)
        try FileManager.default.removeItem(at: corruptURL)
        try Data("changed".utf8).write(to: corruptURL)

        var corruptFailure: Error?
        do {
            _ = try managedFiles.loadVerifiedBlob(for: sendAttachment(for: corrupt), in: store)
        } catch {
            corruptFailure = error
        }
        #expect(corruptFailure != nil)
    }

    @Test("deletingConversationDoesNotDeleteSharedFileAsset")
    func deletingConversationDoesNotDeleteSharedFileAsset() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(applicationSupportRoot: supportRoot)
        let descriptor = try managedFiles.ingest(
            data: Data("shared across conversations".utf8),
            displayName: "shared.txt",
            in: store
        )

        for (conversationID, messageID, runID) in [
            ("conversation-one", "message-one", "run-one"),
            ("conversation-two", "message-two", "run-two"),
        ] {
            var commit = Fixtures.send(
                conversationID: conversationID,
                messageID: messageID,
                runID: runID
            )
            commit.attachments = [MessageAttachmentRecord(
                id: "attachment-\(messageID)",
                messageID: messageID,
                assetID: descriptor.assetID,
                versionID: descriptor.versionID,
                sequence: 0
            )]
            try store.commitUserTurnAndCreateParentRun(commit)
        }

        try store.beginDeletion(conversationID: "conversation-one")
        try store.finalizeDeletion(conversationID: "conversation-one")

        #expect(try store.fileAsset(id: descriptor.assetID) != nil)
        #expect(try store.fileAssetVersion(id: descriptor.versionID)?.contentFingerprint
            == descriptor.fingerprint)
        #expect(FileManager.default.fileExists(
            atPath: try managedFiles.blobURL(forFingerprint: descriptor.fingerprint).path
        ))
        #expect(try store.attachments(forMessage: "message-two").count == 1)
    }

    @Test("databaseWriteFailureRemovesOnlyTheBlobThisRoundPublished")
    func databaseWriteFailureRemovesOnlyTheBlobThisRoundPublished() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            makeIdentifier: { "fixed-identity" }
        )
        let originalBytes = Data("first accepted identity".utf8)
        let original = try managedFiles.ingest(
            data: originalBytes,
            displayName: "original.txt",
            in: store
        )
        let originalURL = try managedFiles.blobURL(forFingerprint: original.fingerprint)
        let newBytes = Data("published before database failure".utf8)
        let newFingerprint = ManagedFileStore.fingerprint(of: newBytes)
        var newBlobFailure: Error?
        do {
            _ = try managedFiles.ingest(data: newBytes, displayName: "new.txt", in: store)
        } catch {
            newBlobFailure = error
        }
        #expect(newBlobFailure != nil)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: try managedFiles.blobURL(forFingerprint: newFingerprint).path
        ))

        var reusedBlobFailure: Error?
        do {
            _ = try managedFiles.ingest(data: originalBytes, displayName: "again.txt", in: store)
        } catch {
            reusedBlobFailure = error
        }
        #expect(reusedBlobFailure != nil)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(try store.fileAssetVersionFingerprints() == [original.fingerprint])
        #expect(try countRows(in: store, table: "fileAsset") == 1)
        #expect(try countRows(in: store, table: "fileAssetVersion") == 1)
    }

    private func temporarySupportRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedFiles-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private func protection(of url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            as? FileProtectionType
    }

    private func countRows(in store: PersistenceStore, table: String) throws -> Int {
        try store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func sendAttachment(
        for descriptor: ManagedFileDescriptor,
        kind: AttachmentKind = .file
    ) -> SendAttachment {
        SendAttachment(
            assetID: descriptor.assetID,
            versionID: descriptor.versionID,
            fingerprint: descriptor.fingerprint,
            kind: kind,
            displayName: descriptor.displayName
        )
    }
}

private struct TemporaryProtectionSample {
    let phase: ManagedFileTemporaryFilePhase
    let protection: FileProtectionType?
}

private final class TemporaryProtectionObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [TemporaryProtectionSample] = []

    func append(phase: ManagedFileTemporaryFilePhase, protection: FileProtectionType?) {
        lock.lock()
        samples.append(TemporaryProtectionSample(phase: phase, protection: protection))
        lock.unlock()
    }

    var all: [TemporaryProtectionSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
