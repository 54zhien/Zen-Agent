#if os(iOS)
import Foundation

enum UserDataFileProtection {
    enum Failure: Error { case protectionUnavailable }
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static func apply(to path: String, fileManager: FileManager = .default) throws {
        try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: path)
#if !targetEnvironment(simulator)
        let value = try fileManager.attributesOfItem(atPath: path)[.protectionKey]
        let actual = (value as? FileProtectionType) ?? (value as? String).map(FileProtectionType.init(rawValue:))
        guard actual == protection else { throw Failure.protectionUnavailable }
#endif
    }

    static func applyToDatabase(at path: String, fileManager: FileManager = .default) throws {
        for file in [path, path + "-wal", path + "-shm"] where fileManager.fileExists(atPath: file) {
            try apply(to: file, fileManager: fileManager)
        }
    }
}
#endif
