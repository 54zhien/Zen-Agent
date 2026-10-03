#if DEBUG
import SwiftUI
import UIKit

@MainActor
struct TimelineDiagnosticProbe: UIViewRepresentable {
    let identifier: String
    let value: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.accessibilityValue = value
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityValue = value
    }
}
#endif
