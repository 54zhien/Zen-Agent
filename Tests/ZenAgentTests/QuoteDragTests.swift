import Foundation
import Testing

@testable import ZenAgent

@Suite("Quote drag probes")
struct QuoteDragTests {

    @Test("source selection rejects cross-part or unfinished parts")
    func sourceSelectionRejectsCrossPartOrUnfinishedPart() {
        let source = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "unfinished-part",
            text: "alpha beta",
            isCompleted: false
        )
        let unfinished = InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: 5)
        )
        #expect(unfinished == nil)

        let firstPart = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "part-a",
            text: "alpha",
            isCompleted: true
        )
        let secondPart = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "part-b",
            text: "beta",
            isCompleted: true
        )
        let firstDrag = InternalQuoteDrag.capture(
            source: firstPart,
            selectedUTF16Range: NSRange(location: 0, length: 5)
        )
        let secondDrag = InternalQuoteDrag.capture(
            source: secondPart,
            selectedUTF16Range: NSRange(location: 0, length: 4)
        )

        #expect(firstDrag?.reference.source.sourcePartID == "part-a")
        #expect(secondDrag?.reference.source.sourcePartID == "part-b")
        #expect(InternalQuoteDrag.capture(
            source: firstPart,
            selectedUTF16Range: NSRange(location: 0, length: 6)
        ) == nil)
    }

    @Test("source selection rejects a range inside a surrogate pair")
    func sourceSelectionRejectsRangeInsideSurrogatePair() {
        let source = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "source-part",
            text: "a😀b",
            isCompleted: true
        )

        #expect(InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(location: 2, length: 1)
        ) == nil)
    }

    @Test("source selection accepts a whole surrogate pair")
    func sourceSelectionAcceptsWholeSurrogatePair() {
        let emoji = "😀"
        let source = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "source-part",
            text: "a\(emoji)b",
            isCompleted: true
        )

        let drag = InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(location: 1, length: 2)
        )

        #expect(drag != nil)
        #expect(drag?.reference.snapshot == emoji)
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

    @Test("a plain external string cannot become a quote reference")
    func localDropRejectsExternalPlainText() {
        #expect(QuoteDragBridge.acceptedReference(
            localObject: "external selection",
            hasLocalDragSession: false,
            existing: []
        ) == nil)
        #expect(QuoteDragBridge.acceptedReference(
            localObject: "external selection",
            hasLocalDragSession: true,
            existing: []
        ) == nil)
    }

    @Test("a repeated source range remains a single reference")
    func duplicateSourceRangeDropKeepsOneReference() {
        let source = QuoteSourceText(
            conversationID: "source-conversation",
            messageID: "source-message",
            partID: "source-part",
            text: "quoted",
            isCompleted: true
        )
        let first = InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: 6)
        )!.reference
        let duplicate = InternalQuoteDrag.capture(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: 6)
        )!
        var references = [first]
        if let accepted = QuoteDropPolicy.acceptedReference(from: duplicate, existing: references) {
            references.append(accepted)
        }
        #expect(references == [first])
    }

    @Test("quote drag suppresses Surface Lift only while active")
    func quoteDragSuppressesSurfaceLiftAndRestoresItOnEnd() {
        let controller = makeController()
        #expect(controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
        controller.handle(.quoteDragPhaseChanged(.active))
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
        controller.handle(.selectionHandleDragChanged(true))
        controller.handle(.quoteDragPhaseChanged(.idle))
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
        controller.handle(.selectionHandleDragChanged(false))
        #expect(controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: true, stableBottomAnchor: true))
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: false))
        controller.handle(.textAreaTapped)
        #expect(!controller.canBeginSurfaceLift(keyboardVisible: false, stableBottomAnchor: true))
    }

    @Test("dropping a quote keeps the Draft text and Resting state")
    func quoteDropKeepsRestingAndDraftTextIntact() {
        let controller = makeController(text: "keep this text")
        controller.updateCollapseProgress(.fullyCollapsed)
        controller.handle(.quoteDragPhaseChanged(.overDropZone))
        let reference = makeReference()
        #expect(controller.addQuoteReference(reference))
        controller.handle(.quoteDragPhaseChanged(.idle))

        #expect(controller.draft.text == "keep this text")
        #expect(controller.draft.references == [reference])
        #expect(controller.draft.presentationState == .resting)
        #expect(controller.effectiveCollapseProgress == .expanded)
    }

    private func makeController(text: String = "") -> ComposerController {
        ComposerController(
            draft: ComposerDraftState(
                text: text,
                selection: ComposerSelection(range: 0..<text.utf16.count),
                references: [],
                attachments: [],
                presentationState: .resting
            ),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "quote-drag-instance"),
                modelID: ModelID(rawValue: "quote-drag-model")
            )
        )
    }

    private func makeReference() -> QuoteReference {
        InternalQuoteDrag.capture(
            source: QuoteSourceText(
                conversationID: "source-conversation",
                messageID: "source-message",
                partID: "source-part",
                text: "quoted text",
                isCompleted: true
            ),
            selectedUTF16Range: NSRange(location: 0, length: 11)
        )!.reference
    }
}
