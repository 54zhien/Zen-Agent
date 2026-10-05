import SwiftUI
import UIKit

@MainActor
struct ComposerHostBridge: UIViewRepresentable {
    let configuration: ComposerHostView.Configuration
    let focused: Bool
    var conversationID = ""
    @Environment(\.workspaceInputSuppressed) private var suppressed
    @Environment(\.workspaceComposerDock) private var dock
    @Environment(\.composerUsesWorkspaceDock) private var usesDock
    @Environment(\.composerIsActivePane) private var isActivePane

    func makeUIView(context: Context) -> ComposerHostPortal {
        let view = ComposerHostPortal()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: ComposerHostPortal, context: Context) { configure(uiView) }

    private func configure(_ view: ComposerHostPortal) {
        view.update(configuration: configuration, focused: focused, suppressed: suppressed,
                    ownerID: conversationID, usesDock: usesDock, dock: dock, isActivePane: isActivePane)
    }
    static func dismantleUIView(_ view: ComposerHostPortal, coordinator: ()) { view.unmount() }
}
