import Foundation
import SwiftUI
import Testing

@testable import ZenAgent

@Suite("Composer text projection")
struct ComposerTextProjectionTests {
    @Test("bothPreviewsReadLatestDraftText")
    func bothPreviewsReadLatestDraftText() {
        var draft = makeDraft(state: .resting, text: "first")
        let restingBeforeEdit = ComposerTextProjection.presentation(for: draft)
        draft.presentationState = .compact
        let compactBeforeEdit = ComposerTextProjection.presentation(for: draft)
        draft.text = "latest full Draft"

        draft.presentationState = .resting
        let resting = ComposerTextProjection.presentation(for: draft)
        draft.presentationState = .compact
        let compact = ComposerTextProjection.presentation(for: draft)
        draft.presentationState = .editing
        let controller = makeController(draft: draft)
        let editorBinding = Binding(
            get: { controller.draft.text },
            set: { controller.draft.text = $0 }
        )

        #expect(restingBeforeEdit == .preview(text: "first", lineLimit: 1, truncation: .tail))
        #expect(compactBeforeEdit == .preview(text: "first", lineLimit: 1, truncation: .tail))
        #expect(resting == .preview(text: "latest full Draft", lineLimit: 1, truncation: .tail))
        #expect(compact == .preview(text: "latest full Draft", lineLimit: 1, truncation: .tail))
        #expect(ComposerTextProjection.presentation(for: draft) == .editor)
        #expect(editorBinding.wrappedValue == "latest full Draft")
        editorBinding.wrappedValue = "edited through binding"
        #expect(controller.draft.text == "edited through binding")
    }

    @Test("previewIsSingleLineTailTruncatedWithoutMutatingDraft")
    func previewIsSingleLineTailTruncatedWithoutMutatingDraft() {
        let fullText = "first line\nsecond line with more content"
        let draft = makeDraft(state: .resting, text: fullText)
        let presentation = ComposerTextProjection.presentation(for: draft)

        #expect(presentation == .preview(text: fullText, lineLimit: 1, truncation: .tail))
        #expect(draft.text == fullText)
    }

    @Test("transitionsPreserveSelectionQuoteAndAttachments")
    func transitionsPreserveSelectionQuoteAndAttachments() {
        let quote = QuoteReference(
            id: "quote-7",
            source: QuoteSourceLocator(
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: "part-7",
                range: QuoteTextRange(utf16Start: 0, utf16Length: "quoted text".utf16.count)
            ),
            snapshot: "quoted text",
            createdAt: Fixtures.epoch
        )
        let attachments = [
            AttachmentReference(
                id: "image-1", versionID: "version-1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))",
                displayName: "diagram.png", kind: .image
            ),
            AttachmentReference(
                id: "file-2", versionID: "version-2",
                fingerprint: "sha256:\(String(repeating: "b", count: 64))",
                displayName: "notes.txt", kind: .file
            ),
        ]
        let selection = ComposerSelection(range: 4..<9)
        let controller = makeController(
            draft: ComposerDraftState(
                text: "keep this draft",
                selection: selection,
                references: [quote],
                attachments: attachments,
                presentationState: .resting
            )
        )

        controller.handle(.textAreaTapped)
        expectMetadata(selection: selection, quote: quote, attachments: attachments, in: controller)
        controller.handle(.conversationBackgroundTapped)
        expectMetadata(selection: selection, quote: quote, attachments: attachments, in: controller)
        controller.updateCollapseProgress(.fullyCollapsed)
        expectMetadata(selection: selection, quote: quote, attachments: attachments, in: controller)
        controller.handle(.compactTapped)
        expectMetadata(selection: selection, quote: quote, attachments: attachments, in: controller)
    }

    private func makeDraft(state: ComposerPresentationState, text: String) -> ComposerDraftState {
        ComposerDraftState(
            text: text,
            selection: ComposerSelection(range: 0..<0),
            references: [],
            attachments: [],
            presentationState: state
        )
    }

    private func makeController(draft: ComposerDraftState) -> ComposerController {
        ComposerController(
            draft: draft,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "composer-test-instance"),
                modelID: ModelID(rawValue: "composer-test-model")
            )
        )
    }

    private func expectMetadata(
        selection: ComposerSelection,
        quote: QuoteReference,
        attachments: [AttachmentReference],
        in controller: ComposerController
    ) {
        #expect(controller.draft.selection == selection)
        #expect(controller.draft.references == [quote])
        #expect(controller.draft.attachments == attachments)
    }
}
