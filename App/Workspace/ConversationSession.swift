import Foundation

/// Warm state survives display eviction without retaining a Timeline or native editor.
@MainActor
final class ConversationSession {
    let conversationID: String
    let composer: ComposerController
    let readingPosition: ReadingPositionController

    init(conversationID: String, configuration: ConversationComposerConfiguration?,
         sendAvailability: ComposerSendAvailability? = nil, tolerance: Double = 12) {
        self.conversationID = conversationID
        composer = ComposerController(configuration: configuration, sendAvailability: sendAvailability)
        readingPosition = ReadingPositionController(tolerance: tolerance)
    }
}
