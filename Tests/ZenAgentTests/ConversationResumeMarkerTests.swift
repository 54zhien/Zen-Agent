import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation resume marker")
struct ConversationResumeMarkerTests {
    @Test("the background time defines the inclusive twenty-minute window")
    func restoreWindow() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let marker = ConversationResumeMarker(conversationID: "conversation", backgroundedAt: start)

        #expect(marker.isWithinRestoreWindow(at: start))
        #expect(marker.isWithinRestoreWindow(at: start.addingTimeInterval(20 * 60)))
        #expect(!marker.isWithinRestoreWindow(at: start.addingTimeInterval(20 * 60 + 1)))
        #expect(!marker.isWithinRestoreWindow(at: start.addingTimeInterval(-1)))
    }

    @Test("the marker is one persisted record and can be consumed")
    func markerStorage() throws {
        let suite = "ZenAgentTests.ResumeMarker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = ConversationResumeMarker(
            conversationID: "conversation",
            backgroundedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )

        marker.write(to: defaults)
        #expect(ConversationResumeMarker.read(from: defaults) == marker)
        ConversationResumeMarker.clear(from: defaults)
        #expect(ConversationResumeMarker.read(from: defaults) == nil)
    }
}
