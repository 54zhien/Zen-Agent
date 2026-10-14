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
        print("OVERLAY_LIFECYCLE at=\(ProcessInfo.processInfo.systemUptime) key=\(key) count=\(count) \(details())")
    }
}
#endif
