import SwiftUI
import UIKit

@MainActor
struct ComposerHostBridge: UIViewRepresentable {
    let configuration: ComposerHostView.Configuration
    let focused: Bool

    func makeUIView(context: Context) -> ComposerHostView {
        let view = ComposerHostView()
        view.configure(configuration)
        return view
    }

    func updateUIView(_ uiView: ComposerHostView, context: Context) {
        uiView.requestFocus(focused)
        uiView.configure(configuration)
    }
}
