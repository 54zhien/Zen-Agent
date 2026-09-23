import CryptoKit
import Foundation

enum ManagedFileStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case invalidFingerprint
    case invalidManagedPath
    case invalidSourceURL
    case protectionMismatch(String)
    case streamReadFailed
    case byteCountOverflow
    case existingBlobMismatch(String)
    case fileAssetMissing(String)
    case fileAssetVersionMissing(String)
    case fileAssetVersionMismatch(assetID: String, versionID: String)
    case fileAssetFingerprintMismatch(String)
    case missingBlob(String)
    case corruptBlob(String)
    case cleanupConfirmationFailed(String)
    case cleanupFailed(String)
}

struct ManagedFileDescriptor: Equatable, Sendable {
    let assetID: String
    let versionID: String
    let fingerprint: String
    let byteCount: Int64
    let mediaType: String?
    let displayName: String
}

enum ManagedFileTemporaryFilePhase: Equatable, Sendable {
    case protectedBeforeWrite
    case protectedAfterWrite
}

/// Stores immutable file bytes by digest and commits their logical identity separately.
/// The process-wide lock keeps recovery from observing the publish-before-database window.
final class ManagedFileStore: @unchecked Sendable {
    private final class OperationLock: @unchecked Sendable {
        let value = NSLock()
    }

    private static let operationLock = OperationLock()

    private static func protectionAttributes() -> [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    let applicationSupportRoot: URL
    let rootURL: URL

    private let fileManager: FileManager
    private let makeIdentifier: @Sendable () -> String
    private let temporaryFileObserver: (@Sendable (URL, ManagedFileTemporaryFilePhase) -> Void)?

    init(
        applicationSupportRoot: URL,
        fileManager: FileManager = .default,
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
        temporaryFileObserver: (@Sendable (URL, ManagedFileTemporaryFilePhase) -> Void)? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
        self.rootURL = applicationSupportRoot
            .appendingPathComponent("ZenAgent", isDirectory: true)
            .appendingPathComponent("FileAssets", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
        self.temporaryFileObserver = temporaryFileObserver
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> ManagedFileStore {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ManagedFileStoreError.applicationSupportUnavailable
        }
        return ManagedFileStore(applicationSupportRoot: root, fileManager: fileManager)
    }

    static func fingerprint(of data: Data) -> String {
        "sha256:" + Self.hex(SHA256.hash(data: data))
    }

    func blobURL(forFingerprint fingerprint: String) throws -> URL {
        guard let digest = Self.digest(from: fingerprint) else {
            throw ManagedFileStoreError.invalidFingerprint
        }
        return blobDirectoryURL(for: digest)
            .appendingPathComponent(digest, isDirectory: false)
    }

    func ingest(
        fileAt sourceURL: URL,
        displayName: String,
        mediaType: String? = nil,
        in store: PersistenceStore
    ) throws -> ManagedFileDescriptor {
        guard sourceURL.isFileURL else {
            throw ManagedFileStoreError.invalidSourceURL
        }
        let input = InputStream(url: sourceURL)
        guard let input else { throw ManagedFileStoreError.invalidSourceURL }
        return try ingest(input, displayName: displayName, mediaType: mediaType, in: store)
    }

    func ingest(
        data: Data,
        displayName: String,
        mediaType: String? = nil,
        in store: PersistenceStore
    ) throws -> ManagedFileDescriptor {
        try ingest(
            InputStream(data: data),
            displayName: displayName,
            mediaType: mediaType,
            in: store
        )
    }

    func ingest(
        _ input: InputStream,
        displayName: String,
        mediaType: String? = nil,
        in store: PersistenceStore
    ) throws -> ManagedFileDescriptor {
        Self.operationLock.value.lock()
        defer { Self.operationLock.value.unlock() }

        _ = try removeUnreferencedBlobsLocked(in: store)
        try ensureStorageDirectories()

        let sourceName = Self.safeDisplayName(displayName)
        let digestDirectory = blobDirectoryURL(for: nil)
        let temporaryURL = digestDirectory.appendingPathComponent(
            ".pending-\(UUID().uuidString)",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: Self.protectionAttributes()
        ) else {
            throw ManagedFileStoreError.invalidSourceURL
        }
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try ensureProtection(on: temporaryURL)
        temporaryFileObserver?(temporaryURL, .protectedBeforeWrite)

        input.open()
        defer { input.close() }
        guard input.streamStatus != .error else {
            throw input.streamError ?? ManagedFileStoreError.streamReadFailed
        }

        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }

        var streamedHasher = SHA256()
        var streamedByteCount: Int64 = 0
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            let readCount = input.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw input.streamError ?? ManagedFileStoreError.streamReadFailed
            }
            if readCount == 0 { break }

            let (nextByteCount, overflow) = streamedByteCount.addingReportingOverflow(Int64(readCount))
            guard !overflow else { throw ManagedFileStoreError.byteCountOverflow }
            streamedByteCount = nextByteCount

            let chunk = Data(bytes: buffer, count: readCount)
            try output.write(contentsOf: chunk)
            streamedHasher.update(data: chunk)
        }

        try output.synchronize()
        try output.close()
        try ensureProtection(on: temporaryURL)
        temporaryFileObserver?(temporaryURL, .protectedAfterWrite)

        let streamedFingerprint = "sha256:" + Self.hex(streamedHasher.finalize())
        let inspectedTemporary = try inspectBlob(at: temporaryURL)
        guard inspectedTemporary.byteCount == streamedByteCount,
              inspectedTemporary.fingerprint == streamedFingerprint
        else {
            throw ManagedFileStoreError.corruptBlob(streamedFingerprint)
        }

        let fingerprint = inspectedTemporary.fingerprint
        guard let digest = Self.digest(from: fingerprint) else {
            throw ManagedFileStoreError.invalidFingerprint
        }
        let destinationURL = try blobURL(forFingerprint: fingerprint)
        try ensureBlobDirectory(for: digest)

        var publishedThisCall = false
        do {
            try publish(
                temporaryURL,
                to: destinationURL,
                fingerprint: fingerprint,
                byteCount: streamedByteCount,
                publishedThisCall: &publishedThisCall
            )

            let assetID = makeIdentifier()
            let versionID = makeIdentifier()
            let now = Date()
            let asset = FileAssetRecord(
                id: assetID,
                displayName: sourceName,
                currentVersionID: versionID,
                origin: .imported,
                createdAt: now,
                updatedAt: now
            )
            let version = FileAssetVersionRecord(
                id: versionID,
                assetID: assetID,
                contentFingerprint: fingerprint,
                byteCount: streamedByteCount,
                mediaType: mediaType,
                createdAt: now
            )

            try store.createFileAsset(asset, initialVersion: version)
            return ManagedFileDescriptor(
                assetID: assetID,
                versionID: versionID,
                fingerprint: fingerprint,
                byteCount: streamedByteCount,
                mediaType: mediaType,
                displayName: sourceName
            )
        } catch {
            if publishedThisCall {
                do {
                    try removeBlobIfUnreferenced(fingerprint, in: store)
                } catch let cleanupError as ManagedFileStoreError {
                    throw cleanupError
                } catch {
                    throw ManagedFileStoreError.cleanupFailed(String(describing: error))
                }
            }
            throw error
        }
    }

    func verifiedBlobURL(
        for attachment: SendAttachment,
        in store: PersistenceStore
    ) throws -> URL {
        Self.operationLock.value.lock()
        defer { Self.operationLock.value.unlock() }
        return try verifiedBlobURLLocked(for: attachment, in: store)
    }

    func loadVerifiedBlob(
        for attachment: SendAttachment,
        in store: PersistenceStore
    ) throws -> Data {
        Self.operationLock.value.lock()
        defer { Self.operationLock.value.unlock() }

        let url = try verifiedBlobURLLocked(for: attachment, in: store)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let version = try store.fileAssetVersion(id: attachment.versionID),
              Int64(data.count) == version.byteCount,
              Self.fingerprint(of: data) == attachment.fingerprint
        else {
            throw ManagedFileStoreError.corruptBlob(attachment.fingerprint)
        }
        return data
    }

    func unreferencedBlobDigests(in store: PersistenceStore) throws -> Set<String> {
        Self.operationLock.value.lock()
        defer { Self.operationLock.value.unlock() }
        let referenced = try store.fileAssetVersionFingerprints()
        return Set(try enumeratedBlobFiles().compactMap { $0.fingerprint })
            .subtracting(referenced)
    }

    @discardableResult
    func removeUnreferencedBlobs(in store: PersistenceStore) throws -> Set<String> {
        Self.operationLock.value.lock()
        defer { Self.operationLock.value.unlock() }
        return try removeUnreferencedBlobsLocked(in: store)
    }

    private func verifiedBlobURLLocked(
        for attachment: SendAttachment,
        in store: PersistenceStore
    ) throws -> URL {
        guard !attachment.assetID.isEmpty,
              !attachment.versionID.isEmpty,
              Self.digest(from: attachment.fingerprint) != nil
        else {
            throw ManagedFileStoreError.invalidFingerprint
        }
        guard try store.fileAsset(id: attachment.assetID) != nil else {
            throw ManagedFileStoreError.fileAssetMissing(attachment.assetID)
        }
        guard let version = try store.fileAssetVersion(id: attachment.versionID) else {
            throw ManagedFileStoreError.fileAssetVersionMissing(attachment.versionID)
        }
        guard version.assetID == attachment.assetID else {
            throw ManagedFileStoreError.fileAssetVersionMismatch(
                assetID: attachment.assetID,
                versionID: attachment.versionID
            )
        }
        guard version.contentFingerprint == attachment.fingerprint else {
            throw ManagedFileStoreError.fileAssetFingerprintMismatch(attachment.versionID)
        }

        let url = try blobURL(forFingerprint: version.contentFingerprint)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ManagedFileStoreError.missingBlob(version.contentFingerprint)
        }
        try ensureManagedPath(url)
        try ensureProtection(on: url)
        let actual = try inspectBlob(at: url)
        guard actual.byteCount == version.byteCount,
              actual.fingerprint == version.contentFingerprint
        else {
            throw ManagedFileStoreError.corruptBlob(version.contentFingerprint)
        }
        return url
    }

    private func publish(
        _ temporaryURL: URL,
        to destinationURL: URL,
        fingerprint: String,
        byteCount: Int64,
        publishedThisCall: inout Bool
    ) throws {
        try ensureManagedPath(destinationURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try ensureProtection(on: destinationURL)
            try verifyExistingBlob(
                at: destinationURL,
                fingerprint: fingerprint,
                byteCount: byteCount
            )
            return
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            publishedThisCall = true
        } catch {
            guard fileManager.fileExists(atPath: destinationURL.path) else { throw error }
            try ensureProtection(on: destinationURL)
            try verifyExistingBlob(
                at: destinationURL,
                fingerprint: fingerprint,
                byteCount: byteCount
            )
            return
        }

        try ensureProtection(on: destinationURL)
        try verifyExistingBlob(
            at: destinationURL,
            fingerprint: fingerprint,
            byteCount: byteCount
        )
    }

    private func verifyExistingBlob(
        at url: URL,
        fingerprint: String,
        byteCount: Int64
    ) throws {
        let actual = try inspectBlob(at: url)
        guard actual.byteCount == byteCount,
              actual.fingerprint == fingerprint
        else {
            throw ManagedFileStoreError.existingBlobMismatch(fingerprint)
        }
    }

    private func inspectBlob(at url: URL) throws -> (byteCount: Int64, fingerprint: String) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber
        else {
            throw ManagedFileStoreError.corruptBlob(url.lastPathComponent)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let (nextByteCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else { throw ManagedFileStoreError.byteCountOverflow }
            byteCount = nextByteCount
            hasher.update(data: chunk)
        }
        guard number.int64Value == byteCount else {
            throw ManagedFileStoreError.corruptBlob(url.lastPathComponent)
        }
        return (byteCount, "sha256:" + Self.hex(hasher.finalize()))
    }

    private func ensureStorageDirectories() throws {
        try createProtectedDirectory(rootURL.deletingLastPathComponent())
        try ensureManagedPath(rootURL)
        try createProtectedDirectory(rootURL)
        try createProtectedDirectory(rootURL.appendingPathComponent("blobs", isDirectory: true))
        try createProtectedDirectory(rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true))
    }

    private func ensureBlobDirectory(for digest: String) throws {
        try ensureStorageDirectories()
        try createProtectedDirectory(blobDirectoryURL(for: digest))
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try ensureManagedPath(url)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: Self.protectionAttributes()
        )
        try ensureProtection(on: url)
    }

    private func setProtection(on url: URL) throws {
        try fileManager.setAttributes(Self.protectionAttributes(), ofItemAtPath: url.path)
    }

    private func ensureProtection(on url: URL) throws {
        try setProtection(on: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        else {
            throw ManagedFileStoreError.protectionMismatch(url.path)
        }
    }

    private func ensureManagedPath(_ url: URL) throws {
        let supportRoot = applicationSupportRoot.resolvingSymlinksInPath().standardizedFileURL
        let expectedNamespace = supportRoot
            .appendingPathComponent("ZenAgent", isDirectory: true)
            .standardizedFileURL
        let expectedRoot = expectedNamespace
            .appendingPathComponent("FileAssets", isDirectory: true)
            .standardizedFileURL
        let namespaceURL = rootURL.deletingLastPathComponent().standardizedFileURL
        let resolvedNamespace = namespaceURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedNamespace.path == expectedNamespace.path,
              resolvedRoot.path == expectedRoot.path
        else {
            throw ManagedFileStoreError.invalidManagedPath
        }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = expectedRoot.path.hasSuffix("/")
            ? expectedRoot.path
            : expectedRoot.path + "/"
        let isManagedPath = resolvedURL.path == expectedNamespace.path
            || resolvedURL.path == expectedRoot.path
            || resolvedURL.path.hasPrefix(rootPrefix)
        guard isManagedPath else {
            throw ManagedFileStoreError.invalidManagedPath
        }

        let namespaceComponents = namespaceURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: namespaceComponents) else {
            throw ManagedFileStoreError.invalidManagedPath
        }
        var currentURL = namespaceURL.deletingLastPathComponent()
        for component in targetComponents.dropFirst(namespaceComponents.count - 1) {
            currentURL = currentURL.appendingPathComponent(component)
            let resources = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resources?.isSymbolicLink == true {
                throw ManagedFileStoreError.invalidManagedPath
            }
            guard fileManager.fileExists(atPath: currentURL.path) else { continue }
            let resources = try currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try fileManager.attributesOfItem(atPath: currentURL.path)
            guard resources.isSymbolicLink != true,
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink
            else {
                throw ManagedFileStoreError.invalidManagedPath
            }
        }
    }

    private func blobDirectoryURL(for digest: String?) -> URL {
        let shaRoot = rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        guard let digest else { return shaRoot }
        return shaRoot.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
    }

    private func removeUnreferencedBlobsLocked(in store: PersistenceStore) throws -> Set<String> {
        let referenced = try store.fileAssetVersionFingerprints()
        let files = try enumeratedBlobFiles()
        var removed = Set<String>()

        for file in files {
            if file.isTemporary {
                try fileManager.removeItem(at: file.url)
                continue
            }
            guard let fingerprint = file.fingerprint,
                  !referenced.contains(fingerprint)
            else { continue }
            try fileManager.removeItem(at: file.url)
            removed.insert(fingerprint)
        }
        return removed
    }

    private func removeBlobIfUnreferenced(
        _ fingerprint: String,
        in store: PersistenceStore
    ) throws {
        let referenced: Set<String>
        do {
            referenced = try store.fileAssetVersionFingerprints()
        } catch {
            throw ManagedFileStoreError.cleanupConfirmationFailed(fingerprint)
        }
        guard !referenced.contains(fingerprint) else { return }
        let url = try blobURL(forFingerprint: fingerprint)
        try ensureManagedPath(url)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ManagedFileStoreError.cleanupFailed(fingerprint)
        }
    }

    private func enumeratedBlobFiles() throws -> [(
        url: URL,
        fingerprint: String?,
        isTemporary: Bool
    )] {
        let shaRoot = rootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256", isDirectory: true)
        try ensureManagedPath(shaRoot)
        guard fileManager.fileExists(atPath: shaRoot.path) else { return [] }
        var files: [(URL, String?, Bool)] = []
        let entries = try fileManager.contentsOfDirectory(
            at: shaRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for url in entries {
            let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard resourceValues.isSymbolicLink != true else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeRegular, url.lastPathComponent.hasPrefix(".pending-") {
                files.append((url, nil, true))
                continue
            }
            let prefix = url.lastPathComponent
            guard type == .typeDirectory,
                  Self.isLowercasePrefix(prefix)
            else { continue }
            try ensureManagedPath(url)
            let children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                let childResources = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard childResources.isSymbolicLink != true else { continue }
                let childAttributes = try fileManager.attributesOfItem(atPath: child.path)
                let name = child.lastPathComponent
                guard childAttributes[.type] as? FileAttributeType == .typeRegular,
                      Self.isLowercaseDigest(name),
                      prefix == String(name.prefix(2))
                else { continue }
                files.append((child, "sha256:" + name, false))
            }
        }
        return files.map { (url: $0.0, fingerprint: $0.1, isTemporary: $0.2) }
    }

    private static func digest(from fingerprint: String) -> String? {
        guard fingerprint.hasPrefix("sha256:") else { return nil }
        let value = String(fingerprint.dropFirst("sha256:".count))
        return isLowercaseDigest(value) ? value : nil
    }

    private static func isLowercaseDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isLowercasePrefix(_ value: String) -> Bool {
        value.count == 2 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeDisplayName(_ input: String) -> String {
        let withoutNulls = input.filter { $0 != "\0" }
        let lastComponent = withoutNulls
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? ""
        guard !lastComponent.isEmpty,
              lastComponent != ".",
              lastComponent != ".."
        else { return "Untitled" }
        return String(lastComponent.prefix(255))
    }
}
