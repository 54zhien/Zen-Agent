import SwiftUI
import UIKit

struct ComposerKeyboardAnimation {
    let duration: TimeInterval
    let curveValue: Int

    var swiftUIAnimation: Animation {
        switch curveValue {
        case UIView.AnimationCurve.easeInOut.rawValue:
            return .easeInOut(duration: duration)
        case UIView.AnimationCurve.easeIn.rawValue:
            return .easeIn(duration: duration)
        case UIView.AnimationCurve.easeOut.rawValue:
            return .easeOut(duration: duration)
        case UIView.AnimationCurve.linear.rawValue:
            return .linear(duration: duration)
        case 7:
            return .easeInOut(duration: duration)
        default:
            return .easeInOut(duration: duration)
        }
    }
}

struct ComposerKeyboardTransition {
    let isVisible: Bool
    let animation: ComposerKeyboardAnimation?
}

struct ComposerTextViewUpdatePolicy: Equatable {
    let writesText: Bool
    let writesSelection: Bool

    static func resolve(markedTextPresent: Bool) -> ComposerTextViewUpdatePolicy {
        ComposerTextViewUpdatePolicy(
            writesText: !markedTextPresent,
            writesSelection: !markedTextPresent
        )
    }
}

@MainActor
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: ComposerSelection
    @Binding var isFocused: Bool

    let isEditing: Bool
    let typographyRole: TypographyRole
    let dynamicTypeSize: DynamicTypeSize
    let textAreaIsScrollable: Bool
    let onCompositionChange: (Bool) -> Void
    let onKeyboardTransition: (ComposerKeyboardTransition) -> Void
    let onMeasuredTextHeight: (CGFloat) -> Void

    static func scaledLineHeight(
        for role: TypographyRole,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        typographyFont(for: role, dynamicTypeSize: dynamicTypeSize).lineHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardDismissMode = .interactive
        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        textView.isUserInteractionEnabled = isEditing
        textView.textContainer.maximumNumberOfLines = isEditing ? 0 : 1
        textView.textContainer.lineBreakMode = isEditing ? .byWordWrapping : .byTruncatingTail
        textView.isScrollEnabled = textAreaIsScrollable
        textView.font = Self.typographyFont(for: typographyRole, dynamicTypeSize: dynamicTypeSize)
        textView.text = text
        textView.selectedRange = Self.nsRange(for: selection, in: text)
        context.coordinator.startObservingKeyboard(for: textView)
        if isFocused {
            textView.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        let policy = ComposerTextViewUpdatePolicy.resolve(
            markedTextPresent: textView.markedTextRange != nil
        )
        if policy.writesText, textView.text != text {
            textView.text = text
        }
        if policy.writesSelection {
            let requestedRange = Self.nsRange(for: selection, in: text)
            if textView.selectedRange != requestedRange {
                textView.selectedRange = requestedRange
            }
        }

        textView.font = Self.typographyFont(for: typographyRole, dynamicTypeSize: dynamicTypeSize)
        textView.isScrollEnabled = textAreaIsScrollable
        textView.keyboardDismissMode = .interactive

        if !isFocused, textView.isFirstResponder, textView.markedTextRange == nil {
            textView.resignFirstResponder()
        }
        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        textView.isUserInteractionEnabled = isEditing
        textView.textContainer.maximumNumberOfLines = isEditing ? 0 : 1
        textView.textContainer.lineBreakMode = isEditing ? .byWordWrapping : .byTruncatingTail
        if isFocused, isEditing, !textView.isFirstResponder,
           textView.markedTextRange == nil {
            textView.becomeFirstResponder()
        }
        context.coordinator.reportMeasuredTextHeight(from: textView)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.stopObservingKeyboard()
    }

    private static func typographyFont(
        for role: TypographyRole,
        dynamicTypeSize: DynamicTypeSize
    ) -> UIFont {
        let traits = UITraitCollection(
            preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize)
        )
        return Typography.uiFont(for: role, compatibleWith: traits)
    }

    private static func nsRange(for selection: ComposerSelection, in text: String) -> NSRange {
        let length = text.utf16.count
        let lower = min(max(0, selection.range.lowerBound), length)
        let upper = min(max(lower, selection.range.upperBound), length)
        return NSRange(location: lower, length: upper - lower)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        private var lastReportedTextHeight: CGFloat?
        private weak var observedTextView: UITextView?
        private var keyboardVisible = false

        init(parent: ComposerTextView) {
            self.parent = parent
            super.init()
        }

        func startObservingKeyboard(for textView: UITextView) {
            observedTextView = textView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardDidHide(_:)),
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
        }

        func stopObservingKeyboard() {
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
            observedTextView = nil
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.onCompositionChange(textView.markedTextRange != nil)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if textView.markedTextRange == nil {
                parent.isFocused = false
                if !keyboardVisible {
                    parent.onKeyboardTransition(ComposerKeyboardTransition(
                        isVisible: false,
                        animation: nil
                    ))
                }
            }
            synchronizeEditorState(from: textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            synchronizeEditorState(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            synchronizeEditorState(from: textView)
        }

        private func synchronizeEditorState(from textView: UITextView) {
            parent.text = textView.text ?? ""
            parent.selection = Self.selection(from: textView)
            parent.onCompositionChange(textView.markedTextRange != nil)
            reportMeasuredTextHeight(from: textView)
        }

        func reportMeasuredTextHeight(from textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let measured = textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            ).height
            guard measured.isFinite,
                  lastReportedTextHeight.map({ abs($0 - measured) > 0.5 }) ?? true else {
                return
            }
            lastReportedTextHeight = measured

            Task { @MainActor [weak self] in
                self?.parent.onMeasuredTextHeight(measured)
            }
        }

        @objc
        private func keyboardDidHide(_ notification: Notification) {
            guard observedTextView?.window != nil else { return }
            keyboardVisible = false
            parent.onKeyboardTransition(ComposerKeyboardTransition(
                isVisible: false,
                animation: nil
            ))
        }

        @objc
        private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = observedTextView?.window else {
                return
            }

            let frameInWindow = window.convert(endFrame, from: nil)
            let isVisible = frameInWindow.minY < window.bounds.maxY && frameInWindow.maxY > 0
            keyboardVisible = isVisible
            let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
            let curveValue = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            let animation: ComposerKeyboardAnimation?
            if let duration, let curveValue {
                animation = ComposerKeyboardAnimation(duration: duration, curveValue: curveValue)
            } else {
                animation = nil
            }
            parent.onKeyboardTransition(
                ComposerKeyboardTransition(isVisible: isVisible, animation: animation)
            )
        }

        private static func selection(from textView: UITextView) -> ComposerSelection {
            let range = textView.selectedRange
            return ComposerSelection(range: range.location..<(range.location + range.length))
        }
    }
}
