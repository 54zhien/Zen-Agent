import SwiftUI

@MainActor
struct ConversationPaneView: View {
    let pane: ConversationPaneController
    let runtime: ConversationRuntime
    let actionBridge: ComposerRuntimeActionBridge
    let maxProviderSteps: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var composerClearance: CGFloat = 62
    private let scrollBridge: ConversationPaneScrollBridge

    init(
        pane: ConversationPaneController,
        runtime: ConversationRuntime,
        actionBridge: ComposerRuntimeActionBridge,
        maxProviderSteps: Int
    ) {
        self.pane = pane
        self.runtime = runtime
        self.actionBridge = actionBridge
        self.maxProviderSteps = maxProviderSteps
        self.scrollBridge = pane.scrollBridge
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ConversationTimelineView(
                projection: pane.liveStore.state.timeline,
                pendingToolApprovals: pane.liveStore.state.pendingToolApprovals,
                runtime: runtime,
                onPendingToolApprovalsChanged: { approvals in
                    pane.liveStore.reconcilePendingToolApprovals(approvals)
                },
                onQuoteReference: { reference in
                    _ = pane.composer.addQuoteReference(reference)
                },
                onQuoteDragPhaseChanged: { phase in
                    _ = pane.composer.handle(.quoteDragPhaseChanged(phase))
                },
                onSelectionHandleDragChanged: { isDragging in
                    _ = pane.composer.handle(.selectionHandleDragChanged(isDragging))
                },
                scrollBridge: scrollBridge,
                bottomComposerClearance: composerClearance
            )
            .accessibilityIdentifier("conversation-pane-approval-\(pane.conversationID)")
            .simultaneousGesture(TapGesture().onEnded {
                guard pane.composer.draft.presentationState == .editing,
                      pane.composer.quoteDragPhase == .idle,
                      !pane.composer.isSelectionHandleDragging else { return }
                _ = pane.composer.handle(.conversationBackgroundTapped)
            })

            ConversationComposerView(
                conversationID: pane.conversationID,
                controller: pane.composer,
                bridge: actionBridge,
                maxProviderSteps: maxProviderSteps,
                onHeightChanged: { composerClearance = $0 }
            )
            .id(ObjectIdentifier(pane.composer))
            .accessibilityIdentifier("conversation-pane-composer-\(pane.conversationID)")
        }
        .overlay(alignment: .bottom) {
            if pane.readingPosition.showsNewContentCapsule {
                NewContentCapsuleView(
                    count: pane.readingPosition.newContentCount,
                    onTap: {
                        _ = pane.updateReading(.tappedNewContent)
                    }
                )
                .font(Typography.font(
                    for: .interfaceCaption,
                    dynamicTypeSize: dynamicTypeSize
                ))
                .padding(.bottom, 96)
            }
        }
        .accessibilityIdentifier("conversation-pane-\(pane.conversationID)")
        .task {
            do {
                try await pane.refreshPendingApprovals(using: runtime)
            } catch {
                // A retry can use the Pane's scoped refresh entry point.
            }
        }
        .onChange(of: pane.liveStore.needsPendingToolApprovalReconciliation) { _, needsRefresh in
            guard needsRefresh else { return }
            Task { @MainActor in
                do {
                    try await pane.refreshPendingApprovals(using: runtime)
                } catch {
                    // Keep this Pane's current approval cards for an explicit retry.
                }
            }
        }
    }
}
