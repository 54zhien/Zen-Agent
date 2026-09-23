import Foundation

struct QuoteTextRange: Equatable, Sendable {
    let utf16Start: Int
    let utf16Length: Int
}

struct QuoteSourceLocator: Equatable, Sendable {
    let sourceConversationID: String
    let sourceMessageID: String
    let sourcePartID: String
    let range: QuoteTextRange
}

struct QuoteReference: Equatable, Sendable {
    let id: String
    let source: QuoteSourceLocator
    let snapshot: String
    let createdAt: Date

}

/// A single completed text Part as it appears in one Conversation. Keeping the Part
/// identity beside its own text means a selection can never span adjacent Parts.
struct QuoteSourceText: Sendable, Equatable {
    let conversationID: String
    let messageID: String
    let partID: String
    let text: String
    let isCompleted: Bool
}

/// Only a value captured from an in-process source can cross the local drag boundary.
/// There is intentionally no initializer from a string or NSItemProvider payload.
struct InternalQuoteDrag: Sendable, Equatable {
    let reference: QuoteReference

    private init(reference: QuoteReference) {
        self.reference = reference
    }

    static func capture(
        source: QuoteSourceText,
        selectedUTF16Range: NSRange
    ) -> InternalQuoteDrag? {
        let identifiers = [source.conversationID, source.messageID, source.partID]
        guard source.isCompleted,
              identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              selectedUTF16Range.location >= 0,
              selectedUTF16Range.length > 0
        else { return nil }

        let sourceText = source.text as NSString
        let utf16Length = sourceText.length
        guard selectedUTF16Range.location <= utf16Length,
              selectedUTF16Range.length <= utf16Length - selectedUTF16Range.location
        else { return nil }

        let snapshot = sourceText.substring(with: selectedUTF16Range)
        guard !snapshot.isEmpty else { return nil }

        let reference = QuoteReference(
            id: UUID().uuidString,
            source: QuoteSourceLocator(
                sourceConversationID: source.conversationID,
                sourceMessageID: source.messageID,
                sourcePartID: source.partID,
                range: QuoteTextRange(
                    utf16Start: selectedUTF16Range.location,
                    utf16Length: selectedUTF16Range.length
                )
            ),
            snapshot: snapshot,
            createdAt: Date()
        )
        return InternalQuoteDrag(reference: reference)
    }
}

enum QuoteDropPolicy {
    static func acceptedReference(
        from drag: InternalQuoteDrag,
        existing: [QuoteReference]
    ) -> QuoteReference? {
        let incoming = drag.reference.source
        let isDuplicate = existing.contains { reference in
            let source = reference.source
            return source.sourceConversationID == incoming.sourceConversationID
                && source.sourceMessageID == incoming.sourceMessageID
                && source.sourcePartID == incoming.sourcePartID
                && source.range == incoming.range
        }
        return isDuplicate ? nil : drag.reference
    }
}
