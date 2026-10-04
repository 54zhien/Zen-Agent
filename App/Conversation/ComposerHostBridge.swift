import SwiftUI
import UIKit

@MainActor
struct ComposerHostBridge: UIViewRepresentable {
    let configuration: ComposerHostView.Configuration
    let focused: Bool
    @Environment(\.workspaceInputSuppressed) private var suppressed

    func makeUIView(context: Context) -> ComposerHostView {
        let view = ComposerHostView()
        view.configure(configuration)
        view.setWorkspaceInputSuppressed(suppressed)
        return view
    }

    func updateUIView(_ uiView: ComposerHostView, context: Context) {
        uiView.configure(configuration)
        uiView.setWorkspaceInputSuppressed(suppressed)
        if !suppressed { uiView.requestFocus(focused) }
        uiView.consumeOverlayFocusIfReady()
    }
}
