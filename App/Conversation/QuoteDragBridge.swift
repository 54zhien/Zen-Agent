import SwiftUI
import UIKit

enum QuoteDragBridge {
    static func acceptedReference(
        localObject: Any?,
        hasLocalDragSession: Bool,
        existing: [QuoteReference]
    ) -> QuoteReference? {
        guard hasLocalDragSession,
              let drag = localObject as? InternalQuoteDrag
        else { return nil }
        return QuoteDropPolicy.acceptedReference(from: drag, existing: existing)
    }
}

@MainActor
struct QuoteSelectableText: UIViewRepresentable {
    let text: String
    let source: QuoteSourceText
    let typographyRole: TypographyRole
    let dynamicTypeSize: DynamicTypeSize
    var maximumNumberOfLines = 0
    var onSingleTap: (() -> Void)? = nil
    var onDragPhaseChanged: (ComposerQuoteDragPhase) -> Void = { _ in }
    var onSelectionHandleDragChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.textDragDelegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.text = text
        updateTypography(textView)

        if onSingleTap != nil {
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.singleTap)
            )
            tap.delegate = context.coordinator
            tap.cancelsTouchesInView = false
            textView.addGestureRecognizer(tap)
        }

        let selectionPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.selectionPanChanged(_:))
        )
        selectionPan.delegate = context.coordinator
        selectionPan.cancelsTouchesInView = false
        selectionPan.delaysTouchesBegan = false
        selectionPan.delaysTouchesEnded = false
        textView.addGestureRecognizer(selectionPan)
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = textView
        if textView.text != text { textView.text = text }
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        updateTypography(textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func updateTypography(_ textView: UITextView) {
        let traits = UITraitCollection(
            preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)
        )
        textView.font = Typography.uiFont(for: typographyRole, compatibleWith: traits)
        textView.textColor = .label
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextDragDelegate, UIGestureRecognizerDelegate {
        var parent: QuoteSelectableText
        weak var textView: UITextView?

        init(parent: QuoteSelectableText) {
            self.parent = parent
        }

        func textDraggableView(
            _ textDraggableView: any UIView & UITextDraggable,
            itemsForDrag dragRequest: any UITextDragRequest
        ) -> [UIDragItem] {
            guard dragRequest.existingItems.isEmpty,
                  dragRequest.isSelected,
                  let textView = textDraggableView as? UITextView
            else { return [] }
            let selection = textView.selectedRange
            guard let drag = InternalQuoteDrag.capture(
                source: parent.source,
                selectedUTF16Range: selection
            ) else { return [] }

            let provider = NSItemProvider(object: drag.reference.snapshot as NSString)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = drag
            return [item]
        }

        func textDraggableView(
            _ textDraggableView: any UIView & UITextDraggable,
            dragSessionWillBegin session: any UIDragSession
        ) {
            parent.onDragPhaseChanged(.active)
        }

        func textDraggableView(
            _ textDraggableView: any UIView & UITextDraggable,
            dragSessionDidEnd session: any UIDragSession,
            withOperation operation: UIDropOperation
        ) {
            parent.onDragPhaseChanged(.idle)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length == 0 {
                parent.onSelectionHandleDragChanged(false)
            }
        }

        @objc
        func selectionPanChanged(_ recognizer: UIPanGestureRecognizer) {
            guard (textView?.selectedRange.length ?? 0) > 0 else { return }
            switch recognizer.state {
            case .began, .changed:
                parent.onSelectionHandleDragChanged(true)
            case .ended, .cancelled, .failed:
                parent.onSelectionHandleDragChanged(false)
            default:
                break
            }
        }

        @objc
        func singleTap() {
            parent.onSingleTap?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

@MainActor
struct QuoteDropTargetView: UIViewRepresentable {
    let existing: [QuoteReference]
    let onAccept: (QuoteReference) -> Void
    let onPhaseChanged: (ComposerQuoteDragPhase) -> Void

    func makeUIView(context: Context) -> QuoteDropTargetUIView {
        let view = QuoteDropTargetUIView()
        view.configure(existing: existing, onAccept: onAccept, onPhaseChanged: onPhaseChanged)
        view.addInteraction(UIDropInteraction(delegate: view))
        return view
    }

    func updateUIView(_ uiView: QuoteDropTargetUIView, context: Context) {
        uiView.configure(existing: existing, onAccept: onAccept, onPhaseChanged: onPhaseChanged)
    }
}

@MainActor
final class QuoteDropTargetUIView: UIView, UIDropInteractionDelegate {
    private var existing: [QuoteReference] = []
    private var onAccept: ((QuoteReference) -> Void)?
    private var onPhaseChanged: ((ComposerQuoteDragPhase) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        existing: [QuoteReference],
        onAccept: @escaping (QuoteReference) -> Void,
        onPhaseChanged: @escaping (ComposerQuoteDragPhase) -> Void
    ) {
        self.existing = existing
        self.onAccept = onAccept
        self.onPhaseChanged = onPhaseChanged
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        guard session.localDragSession != nil else { return false }
        return session.items.contains { $0.localObject is InternalQuoteDrag }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        guard session.localDragSession != nil else { return }
        onPhaseChanged?(.overDropZone)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        guard session.localDragSession != nil else { return }
        onPhaseChanged?(.active)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard session.localDragSession != nil else { return }
        for item in session.items {
            guard let reference = QuoteDragBridge.acceptedReference(
                localObject: item.localObject,
                hasLocalDragSession: session.localDragSession != nil,
                existing: existing
            ) else { continue }
            onAccept?(reference)
            break
        }
        onPhaseChanged?(.idle)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        onPhaseChanged?(.idle)
    }
}
