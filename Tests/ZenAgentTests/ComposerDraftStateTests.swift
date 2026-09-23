import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer draft state")
struct ComposerDraftStateTests {
    @Test("draftKeepsSingleTextSource")
    func draftKeepsSingleTextSource() {
        let quote = quoteReference("quote-1", sourcePartID: "part-1", snapshot: "quoted")
        let attachment = AttachmentReference(
            id: "attachment-1",
            versionID: "version-1",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            displayName: "notes.pdf",
            kind: .file
        )
        var draft = ComposerDraftState(
            text: "original",
            selection: ComposerSelection(range: 2..<4),
            references: [quote],
            attachments: [attachment],
            presentationState: .editing
        )
        let originalSelection = draft.selection
        let originalReferences = draft.references
        let originalAttachments = draft.attachments
        let originalPresentationState = draft.presentationState

        draft.text = "revised"

        #expect(draft.text == "revised")
        #expect(draft.selection == originalSelection)
        #expect(draft.references == originalReferences)
        #expect(draft.attachments == originalAttachments)
        #expect(draft.presentationState == originalPresentationState)
    }

    @Test("copyingDraftDoesNotShareTextStorage")
    func copyingDraftDoesNotShareTextStorage() {
        var draft = ComposerDraftState(
            text: "original",
            selection: ComposerSelection(range: 0..<0),
            references: [],
            attachments: [],
            presentationState: .resting
        )
        var copy = draft

        copy.text = "copy"

        #expect(copy.text == "copy")
        #expect(draft.text == "original")
    }

    @Test("draftPreservesQuoteAndAttachmentsTogether")
    func draftPreservesQuoteAndAttachmentsTogether() {
        let quote = quoteReference("quote-2", sourcePartID: "part-7", snapshot: "important passage")
        let secondQuote = quoteReference("quote-3", sourcePartID: "part-8", snapshot: "another passage")
        let attachments = [
            AttachmentReference(
                id: "image-1", versionID: "version-1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))",
                displayName: "diagram.png", kind: .image
            ),
            AttachmentReference(
                id: "file-2", versionID: "version-2",
                fingerprint: "sha256:\(String(repeating: "b", count: 64))",
                displayName: "brief.txt", kind: .file
            ),
        ]
        let draft = ComposerDraftState(
            text: "Explain these together",
            selection: ComposerSelection(range: 0..<0),
            references: [quote, secondQuote],
            attachments: attachments,
            presentationState: .resting
        )

        #expect(draft.text == "Explain these together")
        #expect(draft.references == [quote, secondQuote])
        #expect(draft.attachments == attachments)
    }

    private func quoteReference(_ id: String, sourcePartID: String, snapshot: String) -> QuoteReference {
        QuoteReference(
            id: id,
            source: QuoteSourceLocator(
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: sourcePartID,
                range: QuoteTextRange(utf16Start: 0, utf16Length: snapshot.utf16.count)
            ),
            snapshot: snapshot,
            createdAt: Fixtures.epoch
        )
    }
}
