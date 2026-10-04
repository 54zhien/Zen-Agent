import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SettingsInputFocus {
    @ObservationIgnored private weak var responder: UIResponder?
    @ObservationIgnored private var completion: (() -> Void)?
    private var revision = 0
    private(set) var isClosing = false
    private(set) var isCancelled = false
    var hasMarkedText: Bool {
        _ = revision
        return (responder as? any UITextInput)?.markedTextRange != nil
    }

    func began(_ responder: UIResponder) {
        guard !isClosing, !isCancelled else { responder.resignFirstResponder(); return }
        self.responder = responder; revision &+= 1
    }
    func changed() { revision &+= 1 }
    func ended(_ responder: UIResponder) {
        guard self.responder === responder else { return }
        self.responder = nil; revision &+= 1
        let callback = completion; completion = nil
        callback?()
    }
    func release(then callback: @escaping () -> Void) {
        guard !isClosing, !isCancelled, !hasMarkedText else { return }
        isClosing = true
        guard let responder else { callback(); return }
        completion = callback
        // The flag clears before didEndEditing. Only this presentation's
        // matching delegate acknowledgement can restore the Composer.
        guard responder.isFirstResponder else { return }
        if !responder.resignFirstResponder() {
            completion = nil; isClosing = false
        }
    }
    func detach(_ responder: UIResponder) {
        if self.responder === responder {
            completion = nil; self.responder = nil; revision &+= 1
        }
        responder.resignFirstResponder()
    }
    func cancel() {
        isCancelled = true; completion = nil
        let previous = responder; responder = nil; revision &+= 1
        previous?.resignFirstResponder()
    }
}

@MainActor
struct SettingsTextField: UIViewRepresentable {
    @Binding var text: String
    let title: String
    let focus: SettingsInputFocus
    var secure = false
    var identifier = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.textColor = .label; field.tintColor = .label
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = title; field.accessibilityLabel = title
        field.accessibilityIdentifier = identifier
        if field.isSecureTextEntry != secure { field.isSecureTextEntry = secure }
        let font = Typography.uiFont(for: .interfaceBody, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)))
        if field.font != font { field.font = font }
        field.isUserInteractionEnabled = !focus.isClosing && !focus.isCancelled
        if field.markedTextRange == nil, field.text != text { field.text = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(34, ceil((uiView.font?.lineHeight ?? 20) + 8)))
    }
    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        coordinator.parent.focus.detach(field)
        field.delegate = nil
        field.removeTarget(coordinator, action: nil, for: .allEvents)
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SettingsTextField
        init(_ parent: SettingsTextField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? ""; parent.focus.changed() }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.focus.began(field) }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focus.ended(field) }
        func textFieldDidChangeSelection(_ field: UITextField) { parent.focus.changed() }
    }
}

@MainActor
struct SettingsInstructionsInput: UIViewRepresentable {
    @Binding var text: String
    let focus: SettingsInputFocus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear; view.textColor = .label; view.tintColor = .label
        view.accessibilityLabel = "Soul 指令"
        view.accessibilityIdentifier = "settings-soul-instructions"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let font = Typography.uiFont(for: .interfaceBody, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)))
        if view.font != font { view.font = font }
        view.isEditable = !focus.isClosing && !focus.isCancelled
        if view.markedTextRange == nil, view.text != text { view.text = text }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.parent.focus.detach(view); view.delegate = nil
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SettingsInstructionsInput
        init(_ parent: SettingsInstructionsInput) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focus.began(view) }
        func textViewDidEndEditing(_ view: UITextView) { parent.focus.ended(view) }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; parent.focus.changed() }
        func textViewDidChangeSelection(_ view: UITextView) { parent.focus.changed() }
    }
}
