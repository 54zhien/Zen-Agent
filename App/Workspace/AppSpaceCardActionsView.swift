import SwiftUI

/// Presentation only: the model owns durable edits and Browse owns selection.
@MainActor
struct AppSpaceCardActionsView: View {
    let model: AppShellModel
    let browse: AppSpaceBrowseController
    let lift: SurfaceLiftController
    let summary: ConversationSummary
    @Binding var requestedID: String?
    @State private var menuPresented = false
    @State private var renamePresented = false
    @State private var capturedID: String?
    @State private var title = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button {
            openMenu()
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("会话菜单")
        .accessibilityIdentifier("workspace-card-menu")
        .disabled(lift.state.phase != .card || model.previewContent.isPreparing || browse.state.phase != .idle)
        .confirmationDialog("会话", isPresented: $menuPresented, titleVisibility: .hidden) {
            Button("重命名") {
                guard isCurrentTarget else { dismiss(); return }
                guard let initialTitle = model.appSpaceConversationTitle(id: summary.id) else { dismiss(); return }
                title = initialTitle
                renamePresented = true
            }
            Button(summary.pinned ? "取消置顶" : "置顶") {
                guard isCurrentTarget, let id = capturedID else { dismiss(); return }
                if model.pinAppSpaceConversation(id: id, pinned: !summary.pinned) { reloadSelection() }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("重命名", isPresented: $renamePresented) {
            TextField("会话标题", text: $title)
            Button("保存") {
                guard isCurrentTarget, let id = capturedID else { dismiss(); return }
                if model.renameAppSpaceConversation(id: id, title: title) { reloadSelection() }
            }
            Button("取消", role: .cancel) { }
        }
        .onChange(of: menuPresented || renamePresented) { _, presented in
            // Logical dismissal must restore native availability even while UIKit
            // still owns its dismissal transition. Input checks actual overlays.
            if presented {
                browse.setInteractionSuspended(true)
                lift.setOverlayPresented(true)
            } else {
                lift.setOverlayPresented(false)
                browse.setInteractionSuspended(false)
                browse.refresh()
            }
        }
        .onChange(of: requestedID) { _, id in
            guard id == summary.id else { return }
            requestedID = nil
            openMenu()
        }
        .onChange(of: browse.selectedConversationID) { _, id in
            if id != capturedID { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dismiss() } }
        .onDisappear { dismiss() }
    }

    private var isCurrentTarget: Bool {
        model.previewContent.isPresented && !model.previewContent.isPreparing
            && browse.selectedConversationID == capturedID && capturedID == summary.id
            && browse.state.phase == .idle && lift.state.phase == .card
    }

    private func openMenu() {
        guard model.previewContent.isPresented, !model.previewContent.isPreparing,
              browse.selectedConversationID == summary.id, browse.state.phase == .idle,
              lift.state.phase == .card, !menuPresented, !renamePresented else { return }
        capturedID = summary.id
        browse.cancel()
        menuPresented = true
    }

    private func reloadSelection() {
        // Menu suspension ends after the native action. Keep the captured ID;
        // refresh re-queries its pinned neighbors in one bounded read.
        lift.setOverlayPresented(false)
        browse.setInteractionSuspended(false)
        browse.refresh()
    }

    private func dismiss() {
        menuPresented = false
        renamePresented = false
        capturedID = nil
        lift.setOverlayPresented(false)
        browse.setInteractionSuspended(false)
    }
}
