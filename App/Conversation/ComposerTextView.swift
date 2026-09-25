import UIKit

/// Prevent SwiftUI projection updates from overwriting an in-progress IME composition.
struct ComposerTextViewUpdatePolicy: Equatable {
    let writesText: Bool
    let writesSelection: Bool

    static func resolve(markedTextPresent: Bool) -> Self {
        Self(writesText: !markedTextPresent, writesSelection: !markedTextPresent)
    }
}

enum ComposerTextMeasurement {
    /// Measure the target multiline layout without changing the visible editor's line mode.
    static func height(text: String, width: CGFloat, font: UIFont) -> CGFloat {
        guard width > 0 else { return font.lineHeight }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return max(font.lineHeight, manager.usedRect(for: container).height)
    }
}
