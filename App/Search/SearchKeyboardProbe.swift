#if DEBUG
import SwiftUI
import UIKit

/// XCTest's Keyboard AX rectangle can exclude the prediction region. Geometry
/// assertions use the native occlusion guide while AX still proves keyboard entry.
@MainActor
struct SearchKeyboardProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> SearchKeyboardProbeView { SearchKeyboardProbeView() }
    func updateUIView(_ view: SearchKeyboardProbeView, context: Context) { view.setNeedsLayout() }
}

@MainActor
final class SearchKeyboardProbeView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "search-native-keyboard-geometry"
        keyboardLayoutGuide.usesBottomSafeArea = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        let frame = convert(keyboardLayoutGuide.layoutFrame, to: window)
        accessibilityValue = "top=\(frame.minY);height=\(frame.height)"
        // Keep the diagnostic itself outside the system keyboard window.
        accessibilityFrame = window.convert(CGRect(x: window.bounds.midX,
            y: window.safeAreaInsets.top + 1, width: 1, height: 1), to: nil)
    }
}
#endif
