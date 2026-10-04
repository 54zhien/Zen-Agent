import SwiftUI
import UIKit

/// Release only Search's responder before restoring the retained Conversation.
/// A scene-wide declarative focus cleanup can otherwise run after that handoff.
@MainActor
final class SearchQueryFocus {
    private weak var field: SearchQueryTextField?
    private(set) var released = false
    private var releaseCompletion: (() -> Void)?

    func attach(_ field: SearchQueryTextField) { self.field = field }

    func release(then completion: @escaping () -> Void) {
        guard !released else { return }
        released = true
        guard let field, field.isFirstResponder else { completion(); return }
        releaseCompletion = completion
        if !field.resignFirstResponder() {
            releaseCompletion = nil
            released = false
        }
    }

    func didEndEditing(_ field: SearchQueryTextField) {
        guard self.field === field, let completion = releaseCompletion else { return }
        releaseCompletion = nil
        completion()
    }

    func detach(_ field: SearchQueryTextField) {
        field.resignFirstResponder()
        if self.field === field { self.field = nil }
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
        requestedInitialFocus = becomeFirstResponder()
    }

    @objc private func textChanged() { onText?(text ?? "") }

    func textFieldDidEndEditing(_ textField: UITextField) { focus.didEndEditing(self) }
}
