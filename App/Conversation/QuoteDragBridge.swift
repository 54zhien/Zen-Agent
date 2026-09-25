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

@MainActor
struct QuoteDropTargetView: UIViewRepresentable {
    private let content: AnyView
    let existing: [QuoteReference]
    let dropFrame: CGRect
    let visualFrame: CGRect
    let dynamicTypeSize: DynamicTypeSize
    let onAccept: (QuoteReference) -> Void
    let onPhaseChanged: (ComposerQuoteDragPhase) -> Void
    let onBackgroundTap: () -> Void

    init<Content: View>(
        existing: [QuoteReference],
        dropFrame: CGRect,
        visualFrame: CGRect,
        dynamicTypeSize: DynamicTypeSize,
        onAccept: @escaping (QuoteReference) -> Void,
        onPhaseChanged: @escaping (ComposerQuoteDragPhase) -> Void,
        onBackgroundTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.content = AnyView(content())
        self.existing = existing
        self.dropFrame = dropFrame
        self.visualFrame = visualFrame
        self.dynamicTypeSize = dynamicTypeSize
        self.onAccept = onAccept
        self.onPhaseChanged = onPhaseChanged
        self.onBackgroundTap = onBackgroundTap
    }

    func makeCoordinator() -> QuoteDropTargetCoordinator {
        QuoteDropTargetCoordinator(
            content: content,
            existing: existing,
            dropFrame: dropFrame,
            dynamicTypeSize: dynamicTypeSize,
            onAccept: onAccept,
            onPhaseChanged: onPhaseChanged
        )
    }

    func makeUIView(context: Context) -> QuoteDropTargetHostUIView {
        let view = QuoteDropTargetHostUIView()
        view.visualFrame = visualFrame
        view.onBackgroundTap = onBackgroundTap
        view.installBackgroundTap()
        view.installDropInteraction(delegate: context.coordinator)
        view.onDidMoveToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attach(to: view)
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: QuoteDropTargetHostUIView, context: Context) {
        uiView.visualFrame = visualFrame
        uiView.onBackgroundTap = onBackgroundTap
        context.coordinator.update(
            content: content,
            transaction: context.transaction,
            existing: existing,
            dropFrame: dropFrame,
            dynamicTypeSize: dynamicTypeSize,
            onAccept: onAccept,
            onPhaseChanged: onPhaseChanged
        )
        uiView.onDidMoveToWindow = { [weak coordinator = context.coordinator, weak uiView] in
            guard let uiView else { return }
            coordinator?.attach(to: uiView)
        }
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(
        _ uiView: QuoteDropTargetHostUIView,
        coordinator: QuoteDropTargetCoordinator
    ) {
        uiView.onDidMoveToWindow = nil
        coordinator.detach(from: uiView)
    }
}

@MainActor
final class QuoteDropTargetHostUIView: UIView, UIGestureRecognizerDelegate {
    private weak var hostedView: UIView?
    private var dropInteraction: UIDropInteraction?
    var onDidMoveToWindow: (() -> Void)?
    var visualFrame: CGRect = .zero
    var onBackgroundTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedView?.frame = bounds
    }

    func installDropInteraction(delegate: UIDropInteractionDelegate) {
        guard dropInteraction == nil else { return }
        let interaction = UIDropInteraction(delegate: delegate)
        addInteraction(interaction)
        dropInteraction = interaction
    }

    func installBackgroundTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        !visualFrame.contains(touch.location(in: self))
    }

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              !visualFrame.contains(recognizer.location(in: self)) else { return }
        onBackgroundTap?()
    }

    func installHostedView(_ view: UIView) {
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        hostedView = view
        // Keep hosted content and dropFrame in the same local coordinate space.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.frame = bounds
    }
}

@MainActor
final class QuoteDropTargetCoordinator: NSObject, UIDropInteractionDelegate {
    private let hostingController: UIHostingController<AnyView>
    private weak var hostView: QuoteDropTargetHostUIView?
    private var existing: [QuoteReference] = []
    private var dropFrame: CGRect = .zero
    private var phase: ComposerQuoteDragPhase = .idle
    private var onAccept: ((QuoteReference) -> Void)?
    private var onPhaseChanged: ((ComposerQuoteDragPhase) -> Void)?

    init(
        content: AnyView,
        existing: [QuoteReference],
        dropFrame: CGRect,
        dynamicTypeSize: DynamicTypeSize,
        onAccept: @escaping (QuoteReference) -> Void,
        onPhaseChanged: @escaping (ComposerQuoteDragPhase) -> Void
    ) {
        hostingController = UIHostingController(
            rootView: Self.hostedContent(content, dynamicTypeSize: dynamicTypeSize)
        )
        self.existing = existing
        self.dropFrame = dropFrame
        self.onAccept = onAccept
        self.onPhaseChanged = onPhaseChanged
        super.init()
        // The outer GeometryReader already resolves the safe-area and keyboard layout.
        hostingController.safeAreaRegions = []
        hostingController.view.backgroundColor = .clear
    }

    func update(
        content: AnyView,
        transaction: Transaction,
        existing: [QuoteReference],
        dropFrame: CGRect,
        dynamicTypeSize: DynamicTypeSize,
        onAccept: @escaping (QuoteReference) -> Void,
        onPhaseChanged: @escaping (ComposerQuoteDragPhase) -> Void
    ) {
        // A new hosting root otherwise drops the animation transaction that
        // moves the keyboard, Composer shell, controls and placeholder together.
        withTransaction(transaction) {
            hostingController.rootView = Self.hostedContent(content, dynamicTypeSize: dynamicTypeSize)
        }
        self.existing = existing
        self.dropFrame = dropFrame
        self.onAccept = onAccept
        self.onPhaseChanged = onPhaseChanged
    }

    func attach(to hostView: QuoteDropTargetHostUIView) {
        self.hostView = hostView
        guard hostView.window != nil,
              let parent = enclosingViewController(for: hostView)
        else { return }

        let needsParent = hostingController.parent !== parent
        if needsParent, hostingController.parent != nil {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        if needsParent {
            parent.addChild(hostingController)
        }
        hostView.installHostedView(hostingController.view)
        if needsParent {
            hostingController.didMove(toParent: parent)
        }
    }

    func detach(from hostView: QuoteDropTargetHostUIView) {
        guard self.hostView === hostView else { return }
        self.hostView = nil
        guard hostingController.parent != nil else {
            hostingController.view.removeFromSuperview()
            return
        }
        hostingController.willMove(toParent: nil)
        hostingController.view.removeFromSuperview()
        hostingController.removeFromParent()
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        hasLocalQuote(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        guard hasLocalQuote(session) else { return }
        updatePhase(for: session)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession
    ) -> UIDropProposal {
        guard hasLocalQuote(session) else {
            return UIDropProposal(operation: .forbidden)
        }
        guard let hostView,
              QuoteDropRegion.contains(session.location(in: hostView), in: dropFrame)
        else {
            setPhase(.active)
            return UIDropProposal(operation: .forbidden)
        }
        setPhase(.overDropZone)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        guard hasLocalQuote(session) else { return }
        setPhase(.active)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        defer { setPhase(.idle) }
        guard hasLocalQuote(session),
              let hostView,
              QuoteDropRegion.contains(session.location(in: hostView), in: dropFrame)
        else { return }

        for item in session.items {
            guard let reference = QuoteDragBridge.acceptedReference(
                localObject: item.localObject,
                hasLocalDragSession: session.localDragSession != nil,
                existing: existing
            ) else { continue }
            onAccept?(reference)
            break
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        setPhase(.idle)
    }

    private func hasLocalQuote(_ session: any UIDropSession) -> Bool {
        session.localDragSession != nil
            && session.items.contains { $0.localObject is InternalQuoteDrag }
    }

    private func updatePhase(for session: any UIDropSession) {
        guard let hostView,
              QuoteDropRegion.contains(session.location(in: hostView), in: dropFrame)
        else {
            setPhase(.active)
            return
        }
        setPhase(.overDropZone)
    }

    private func setPhase(_ phase: ComposerQuoteDragPhase) {
        guard self.phase != phase else { return }
        self.phase = phase
        onPhaseChanged?(phase)
    }

    private func enclosingViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }

    private static func hostedContent(_ content: AnyView, dynamicTypeSize: DynamicTypeSize) -> AnyView {
        // Nested hosting starts a new SwiftUI environment, so forward the value this subtree reads.
        AnyView(content.environment(\.dynamicTypeSize, dynamicTypeSize))
    }
}

enum QuoteDropRegion {
    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        frame.contains(point)
    }
}
