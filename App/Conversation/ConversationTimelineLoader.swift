import Foundation

enum ConversationTimelineLoader {
    static func load(conversationID: String, from store: PersistenceStore) throws -> ConversationTimelineProjection {
        try project(conversationID: conversationID, snapshot: store.conversationHistory(id: conversationID))
    }

    static func project(conversationID: String,
                        snapshot: ConversationHistorySnapshot) throws -> ConversationTimelineProjection {
        try Task.checkCancellation()
        let messages = Dictionary(uniqueKeysWithValues: snapshot.messages.map { ($0.id, $0) })
        let parts = Dictionary(grouping: snapshot.parts, by: \.messageID)
        let calls = Dictionary(uniqueKeysWithValues: snapshot.calls.map { ($0.id, $0) })
        let results = Dictionary(uniqueKeysWithValues: snapshot.results.map { ($0.toolCallID, $0) })
        let quotes = Dictionary(grouping: snapshot.quotes.map {
            QuoteReferencePresentation(reference: $0, sourceIsAvailable: snapshot.availableQuoteIDs.contains($0.id))
        }, by: { $0.reference.messageID })
        try Task.checkCancellation()
        let input = ConversationTimelineInput(conversationID: conversationID, runs: snapshot.runs,
            messagesByID: messages, partsByMessageID: parts, toolCallsByID: calls,
            toolResultsByToolCallID: results, quoteReferencesByMessageID: quotes)
        let projection = ConversationTimelineProjection.build(from: input)
        try Task.checkCancellation()
        return projection
    }
}
