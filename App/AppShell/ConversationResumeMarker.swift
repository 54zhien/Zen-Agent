import Foundation

/// A background transition is the last reliable point at which iOS can record
/// the active conversation before a later cold launch.
struct ConversationResumeMarker: Equatable {
    static let storageKey = "zen.w1.lastBackgroundConversation.v1"
    static let restoreWindow: TimeInterval = 20 * 60

    let conversationID: String
    let backgroundedAt: Date

    func isWithinRestoreWindow(at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(backgroundedAt)
        return elapsed >= 0 && elapsed <= Self.restoreWindow
    }

    static func read(from defaults: UserDefaults) -> Self? {
        guard let value = defaults.dictionary(forKey: storageKey),
              let conversationID = value["conversationID"] as? String,
              !conversationID.isEmpty,
              let timestamp = value["backgroundedAt"] as? Double,
              timestamp.isFinite else {
            return nil
        }
        return Self(
            conversationID: conversationID,
            backgroundedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    func write(to defaults: UserDefaults) {
        defaults.set(
            [
                "conversationID": conversationID,
                "backgroundedAt": backgroundedAt.timeIntervalSince1970
            ],
            forKey: Self.storageKey
        )
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }
}
