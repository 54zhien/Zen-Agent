import Foundation

/// Reads a conversation out of the store and hands the projection a plain value.
///
/// The projection stays pure; everything that can throw (database access, ordering) happens here.
enum ConversationTimelineLoader {

    static func load(
        conversationID: String,
        from store: PersistenceStore
    ) throws -> ConversationTimelineProjection {
        let allRuns = try store.runs(inConversation: conversationID)
        let parentRuns = allRuns.filter { $0.kind == .parent }

        // One read for the conversation's messages, indexed once — not one read per message.
        let messages = try store.messages(inConversation: conversationID)
        var messagesByID: [String: MessageRecord] = [:]
        for message in messages { messagesByID[message.id] = message }

        var partsByMessageID: [String: [MessagePartRecord]] = [:]
        var toolCallsByID: [String: ToolCallRecord] = [:]
        var toolResultsByToolCallID: [String: ToolResultRecord] = [:]
        var quoteReferencesByMessageID: [String: [QuoteReferencePresentation]] = [:]

        for run in parentRuns {
            let calls = try store.toolCalls(inRun: run.id)
            for call in calls { toolCallsByID[call.id] = call }

            let results = try store.toolResults(forToolCallIDs: calls.map(\.id))
            for result in results { toolResultsByToolCallID[result.toolCallID] = result }

            for messageID in [run.triggerMessageID, run.responseMessageID].compactMap({ $0 })
            where partsByMessageID[messageID] == nil {
                partsByMessageID[messageID] = try store.parts(ofMessage: messageID)
            }

            if let triggerMessageID = run.triggerMessageID,
               quoteReferencesByMessageID[triggerMessageID] == nil {
                quoteReferencesByMessageID[triggerMessageID] = try store
                    .quoteReferences(forMessageID: triggerMessageID)
                    .map { reference in
                        QuoteReferencePresentation(
                            reference: reference,
                            sourceIsAvailable: try store.quoteSourceIsAvailable(reference)
                        )
                    }
            }
        }

        let input = ConversationTimelineInput(
            conversationID: conversationID,
            runs: allRuns,
            messagesByID: messagesByID,
            partsByMessageID: partsByMessageID,
            toolCallsByID: toolCallsByID,
            toolResultsByToolCallID: toolResultsByToolCallID,
            quoteReferencesByMessageID: quoteReferencesByMessageID
        )
        return ConversationTimelineProjection.build(from: input)
    }
}
