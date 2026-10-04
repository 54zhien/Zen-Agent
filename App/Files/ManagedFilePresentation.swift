import CryptoKit
import Foundation

/// A native controller retains this lease until dismissal, independently of the catalog.
final class ManagedFilePresentation: @unchecked Sendable {
    let url: URL
    private let cleanup: @Sendable () -> Void

    init(url: URL, cleanup: @escaping @Sendable () -> Void) {
        self.url = url; self.cleanup = cleanup
    }

    deinit {
        let cleanup = cleanup
        Task.detached { cleanup() }
    }
}

extension ManagedFileStore {
    func makePresentationCopy(for attachment: SendAttachment,
                              in store: PersistenceStore) throws -> ManagedFilePresentation {
        try withVerifiedBlob(for: attachment, in: store) { source in
            let root = try FilePresentationCache.validatedRoot(presentationCacheRoot)
            try FilePresentationCache.prepare(root, protection: protectionRequirement)
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let destination = folder.appendingPathComponent(
                FilePresentationCache.safeName(attachment.displayName), isDirectory: false)
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: folder) } }
            guard folder.resolvingSymlinksInPath().standardizedFileURL == folder,
                  (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw ManagedFileStoreError.invalidManagedPath
            }
            try FilePresentationCache.prepare(folder, protection: protectionRequirement)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw ManagedFileStoreError.invalidSourceURL
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hash = SHA256()
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task<Never, Never>.checkCancellation()
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
            }
            try output.synchronize(); try output.close()
            let fingerprint = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard fingerprint == attachment.fingerprint else {
                throw ManagedFileStoreError.corruptBlob(attachment.fingerprint)
            }
            try FilePresentationCache.ensureProtection(destination, requirement: protectionRequirement)
            try Task<Never, Never>.checkCancellation()
            FilePresentationCache.leases.folders.insert(folder.path)
            retained = true
            return ManagedFilePresentation(url: destination) { [self] in
                withFileOperation {
                    FilePresentationCache.leases.folders.remove(folder.path)
                    // Delete only this owned UUID directory, never a followed symlink.
                    guard (try? FilePresentationCache.validatedRoot(presentationCacheRoot)) == root,
                          FilePresentationCache.isOwnedFolder(folder, in: root) else { return }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }

    /// Only unleased, owned presentation copies; managed bytes and Session data are excluded.
    @discardableResult
    func clearPresentationCache() throws -> Int {
        try withFileOperation {
            let root = try FilePresentationCache.validatedRoot(presentationCacheRoot)
            guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
            let folders = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var count = 0
            for folder in folders where !FilePresentationCache.leases.folders.contains(folder.path) {
                guard FilePresentationCache.isOwnedFolder(folder, in: root) else { continue }
                try FileManager.default.removeItem(at: folder)
                count += 1
            }
            return count
        }
    }
}

private enum FilePresentationCache {
    // Accessed only under ManagedFileStore's existing process-wide operation lock.
    final class Leases: @unchecked Sendable { var folders: Set<String> = [] }
    static let leases = Leases()

    static func validatedRoot(_ configured: URL) throws -> URL {
        let expected = configured.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(configured.lastPathComponent, isDirectory: true).standardizedFileURL
        guard configured.resolvingSymlinksInPath().standardizedFileURL == expected,
              (try? configured.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ManagedFileStoreError.invalidManagedPath
        }
        return expected
    }

    static func isOwnedFolder(_ folder: URL, in root: URL) -> Bool {
        guard folder.deletingLastPathComponent().standardizedFileURL == root,
              UUID(uuidString: folder.lastPathComponent) != nil,
              let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL else { return false }
        return true
    }

    static func prepare(_ directory: URL, protection: ProtectionRequirement) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try ensureProtection(directory, requirement: protection)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func ensureProtection(_ url: URL, requirement: ProtectionRequirement) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        if requirement == .enforced {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication else {
                throw ManagedFileStoreError.protectionMismatch(url.path)
            }
        }
    }

    static func safeName(_ displayName: String) -> String {
        let component = displayName.filter { $0 != "\0" }.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""
        var name = ""
        for character in component {
            guard name.utf8.count + String(character).utf8.count <= 255 else { break }
            name.append(character)
        }
        return name.isEmpty || name == "." || name == ".." ? "File" : name
    }
}
