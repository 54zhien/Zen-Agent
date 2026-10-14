#if DEBUG
import Foundation

@MainActor
enum OverlayLifecycleDiagnostic {
    private static var counts: [String: Int] = [:]
    static func record(_ key: String, _ details: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["ZEN_OVERLAY_LIFECYCLE_TRACE"] == "1" else { return }
        counts[key, default: 0] += 1
        let count = counts[key, default: 0]
        guard count <= 6 || count == 100 || count == 1000 || count == 10000 else { return }
        let line = "OVERLAY_LIFECYCLE at=\(ProcessInfo.processInfo.systemUptime) key=\(key) count=\(count) \(details())"
        print(line)
        // UI-test app stdout is not forwarded into xcodebuild's test log.
        // Persist the same bounded records for post-test simulator export.
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("overlay-lifecycle-\(ProcessInfo.processInfo.processIdentifier).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data((line + "\n").utf8))
        } catch { /* Observation must not change the presentation path. */ }
    }
}
#endif
