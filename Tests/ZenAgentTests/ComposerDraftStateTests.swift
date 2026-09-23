import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer draft state")
struct ComposerDraftStateTests {
    @Test("draftKeepsSingleTextSource")
    func draftKeepsSingleTextSource() {
        let quote = QuoteReference(sourceID: "message-1", snapshot: "quoted")
        let attachment = AttachmentReference(
            id: "attachment-1",
            displayName: "notes.pdf",
            kind: .file
        )
        var draft = ComposerDraftState(
            text: "original",
            selection: ComposerSelection(range: 2..<4),
            quoteReference: quote,
            attachments: [attachment],
            presentationState: .editing
        )
        let originalSelection = draft.selection
        let originalQuote = draft.quoteReference
        let originalAttachments = draft.attachments
        let originalPresentationState = draft.presentationState

        draft.text = "revised"

        #expect(draft.text == "revised")
        #expect(draft.selection == originalSelection)
        #expect(draft.quoteReference == originalQuote)
        #expect(draft.attachments == originalAttachments)
        #expect(draft.presentationState == originalPresentationState)
    }

    @Test("copyingDraftDoesNotShareTextStorage")
    func copyingDraftDoesNotShareTextStorage() {
        var draft = ComposerDraftState(
            text: "original",
            selection: ComposerSelection(range: 0..<0),
            quoteReference: nil,
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
        let quote = QuoteReference(sourceID: "part-7", snapshot: "important passage")
        let attachments = [
            AttachmentReference(id: "image-1", displayName: "diagram.png", kind: .image),
            AttachmentReference(id: "file-2", displayName: "brief.txt", kind: .file),
        ]
        let draft = ComposerDraftState(
            text: "Explain these together",
            selection: ComposerSelection(range: 0..<0),
            quoteReference: quote,
            attachments: attachments,
            presentationState: .resting
        )

        #expect(draft.text == "Explain these together")
        #expect(draft.quoteReference == quote)
        #expect(draft.attachments == attachments)
    }
}
