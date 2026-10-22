import CryptoKit
import Foundation

/// A witness over the exact persisted bytes, not a second executable payload.
/// Re-encoding or replacing a frozen intent must invalidate its old approval.
enum ToolIntentBinding {
    static func make(_ frozenJSON: String) -> String {
        "sha256:" + SHA256.hash(data: Data(frozenJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
