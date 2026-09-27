import SwiftUI
import UIKit
import QuartzCore

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
        context.coordinator.render(text, in: textView, role: typographyRole,
                                   dynamicTypeSize: dynamicTypeSize)

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
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        context.coordinator.render(text, in: textView, role: typographyRole,
                                   dynamicTypeSize: dynamicTypeSize)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.stopRevealing()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextDragDelegate, UIGestureRecognizerDelegate {
        var parent: QuoteSelectableText
        weak var textView: UITextView?
        private struct RevealEntry {
            let range: NSRange
            let start: CFTimeInterval
        }
        private var renderedText: String?
        private var renderedFont: UIFont?
        private var renderedTracking: CGFloat = 0
        private var renderedLineSpacing: CGFloat = 0
        private var reveals: [RevealEntry] = []
        private var displayLink: CADisplayLink?

        init(parent: QuoteSelectableText) {
            self.parent = parent
        }

        func render(_ text: String, in textView: UITextView, role: TypographyRole,
                    dynamicTypeSize: DynamicTypeSize) {
            let traits = UITraitCollection(
                preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)
            )
            let font = Typography.uiFont(for: role, compatibleWith: traits)
            let spacing = Typography.readingSpacing(for: role)
            let typographyChanged = renderedFont != font
                || renderedTracking != spacing.tracking
                || renderedLineSpacing != spacing.lineSpacing
            guard renderedText != text || typographyChanged else { return }

            let previous = renderedText
            let appendOnly = !typographyChanged && previous.map(text.hasPrefix) == true
            if !appendOnly {
                reveals.removeAll()
            }
            let now = CACurrentMediaTime()
            if appendOnly, role == .conversationBody, !UIAccessibility.isReduceMotionEnabled,
               let previous, text != previous {
                var offset = previous.utf16.count
                let suffix = text.dropFirst(previous.count)
                var lastStart = reveals.last?.start ?? now - 0.018
                for character in suffix.prefix(64) {
                    lastStart = min(max(now, lastStart + 0.018), now + 0.4)
                    let length = String(character).utf16.count
                    reveals.append(RevealEntry(
                        range: NSRange(location: offset, length: length), start: lastStart
                    ))
                    offset += length
                }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing.lineSpacing
            let styled = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .kern: spacing.tracking,
                .paragraphStyle: paragraph
            ])
            let selection = textView.selectedRange
            textView.attributedText = styled
            if selection.location <= text.utf16.count,
               selection.location + selection.length <= text.utf16.count {
                textView.selectedRange = selection
            }
            renderedText = text
            renderedFont = font
            renderedTracking = spacing.tracking
            renderedLineSpacing = spacing.lineSpacing
            updateReveal(at: now)
            if !reveals.isEmpty && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(revealFrame))
                link.preferredFramesPerSecond = 30
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        func stopRevealing() {
            displayLink?.invalidate()
            displayLink = nil
            reveals.removeAll()
        }

        @objc private func revealFrame() {
            updateReveal(at: CACurrentMediaTime())
        }

        private func updateReveal(at now: CFTimeInterval) {
            guard let textView else { stopRevealing(); return }
            let storage = textView.textStorage
            storage.beginEditing()
            for entry in reveals where NSMaxRange(entry.range) <= storage.length {
                let progress = min(1, max(0, (now - entry.start) / 0.2))
                storage.addAttribute(
                    .foregroundColor,
                    value: UIColor.label.withAlphaComponent(CGFloat(progress)),
                    range: entry.range
                )
                storage.addAttribute(
                    .baselineOffset,
                    value: CGFloat((progress - 1) * 2),
                    range: entry.range
                )
            }
            storage.endEditing()
            reveals.removeAll { now >= $0.start + 0.2 }
            if reveals.isEmpty {
                displayLink?.invalidate()
                displayLink = nil
            }
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
            with operation: UIDropOperation
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

enum QuoteDropRegion {
    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        frame.contains(point)
    }
}
