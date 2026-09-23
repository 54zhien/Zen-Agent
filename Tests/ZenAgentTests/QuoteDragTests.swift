import Foundation
import Testing

@testable import ZenAgent

@Suite("Quote drag probes")
struct QuoteDragTests {

    @Test("source selection rejects cross-part or unfinished parts")
    func sourceSelectionRejectsCrossPartOrUnfinishedPart() {
        let range = QuoteTextRange(utf16Start: 0, utf16Length: 5)
        let locator = QuoteSourceLocator(
            sourceConversationID: "source-conversation",
            sourceMessageID: "source-message",
            sourcePartID: "source-part",
            range: range
        )
        let source = QuoteSourceText(
            conversationID: locator.sourceConversationID,
            messageID: locator.sourceMessageID,
            partID: locator.sourcePartID,
            text: "alpha beta",
            isCompleted: false
        )

        let drag = InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(
                location: locator.range.utf16Start,
                length: locator.range.utf16Length
            )
        )

        #expect(drag == nil)
    }

    @Test("a valid quote drag opens Compact into Resting without focus")
    func compactValidDragOpensRestingWithoutFocus() {
        let controller = ComposerController(
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "quote-drag-instance"),
                modelID: ModelID(rawValue: "quote-drag-model")
            )
        )
        let compactTransition = controller.updateCollapseProgress(.fullyCollapsed)
        let dragPhase: ComposerQuoteDragPhase = .overDropZone

        #expect(compactTransition.targetState == .compact)
        let dropTransition = controller.handle(.quoteDragPhaseChanged(dragPhase))
        #expect(dropTransition.targetState == .resting)
        #expect(dropTransition.focusCommand == .none)
        #expect(controller.draft.presentationState == .resting)
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
    }
}
