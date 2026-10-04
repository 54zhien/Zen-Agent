import SwiftUI
import UIKit

/// Release only Search's responder before restoring the retained Conversation.
/// A scene-wide declarative focus cleanup can otherwise run after that handoff.
@MainActor
final class SearchQueryFocus {
    private enum Phase: Equatable { case active, releasing, released, cancelled }
    private weak var field: SearchQueryTextField?
    private var phase = Phase.active
    var released: Bool { phase != .active }
    private var releaseCompletion: (() -> Void)?

    func attach(_ field: SearchQueryTextField) {
        releaseCompletion = nil
        // Replacement cancels the old unacknowledged request, but the same
        // still-open presentation must permit a fresh Close. A completed or
        // cancelled presentation cannot reacquire focus during its fade.
        if phase == .releasing { phase = .active }
        self.field = field
    }

    func release(then completion: @escaping () -> Void) {
        guard phase == .active else { return }
        phase = .releasing
        guard let field, field.isFirstResponder else {
            phase = .released
            completion()
            return
        }
        releaseCompletion = completion
        if !field.resignFirstResponder() {
            releaseCompletion = nil
            phase = .active
        }
    }

    func didEndEditing(_ field: SearchQueryTextField) {
        guard self.field === field, let completion = releaseCompletion else { return }
        releaseCompletion = nil
        phase = .released
        completion()
    }

    func detach(_ field: SearchQueryTextField) {
        if self.field === field {
            releaseCompletion = nil
            if phase == .releasing { phase = .active }
            self.field = nil
        }
        field.resignFirstResponder()
    }

    func cancel() {
        phase = .cancelled
        releaseCompletion = nil
    }
}

@MainActor
struct SearchQueryInput: UIViewRepresentable {
    let text: String
    let font: UIFont
    let focus: SearchQueryFocus
    let onText: (String) -> Void

    func makeUIView(context: Context) -> SearchQueryTextField {
        let field = SearchQueryTextField(focus: focus)
        configure(field)
        return field
    }

    func updateUIView(_ field: SearchQueryTextField, context: Context) { configure(field) }

    private func configure(_ field: SearchQueryTextField) {
        field.onText = onText
        field.font = font
        if field.markedTextRange == nil, field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SearchQueryTextField,
                     context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: ceil((uiView.font?.lineHeight ?? 20) + 4))
    }

    static func dismantleUIView(_ field: SearchQueryTextField, coordinator: ()) {
        field.focus.detach(field)
        field.onText = nil
    }
}

@MainActor
final class SearchQueryTextField: UITextField, UITextFieldDelegate {
    let focus: SearchQueryFocus
    var onText: ((String) -> Void)?
    private var requestedInitialFocus = false

    init(focus: SearchQueryFocus) {
        self.focus = focus
        super.init(frame: .zero)
        focus.attach(self)
        placeholder = "搜索会话标题"
        accessibilityIdentifier = "conversation-search-input"
        autocapitalizationType = .none
        autocorrectionType = .no
        returnKeyType = .search
        delegate = self
        textColor = .label
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTarget(self, action: #selector(textChanged), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() { super.didMoveToWindow(); requestInitialFocusIfReady() }
    override func layoutSubviews() { super.layoutSubviews(); requestInitialFocusIfReady() }

    private func requestInitialFocusIfReady() {
        guard !focus.released, !requestedInitialFocus, window != nil,
              bounds.width > 0, bounds.height > 0 else { return }
        requestedInitialFocus = true
        if !becomeFirstResponder() { requestedInitialFocus = false }
    }

    @objc private func textChanged() { onText?(text ?? "") }

    func textFieldDidEndEditing(_ textField: UITextField) { focus.didEndEditing(self) }
}
