import SwiftUI

private struct ConversationBottomNoticeKey: EnvironmentKey {
    static var defaultValue: AnyView? { nil }
}

extension EnvironmentValues {
    var conversationBottomNotice: AnyView? {
        get { self[ConversationBottomNoticeKey.self] }
        set { self[ConversationBottomNoticeKey.self] = newValue }
    }
}

@MainActor
struct ConversationPaneView: View {
    let pane: ConversationPaneController
    let runtime: ConversationRuntime
    let actionBridge: ComposerRuntimeActionBridge
    let maxProviderSteps: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.conversationBottomNotice) private var bottomNotice
    @Environment(\.workspaceNavigation) private var navigation
    @Environment(\.workspaceComposerDock) private var dock
    private let usesSharedComposer: Bool
    private let reservesSharedComposer: Bool
    @State private var composerClearance: CGFloat = 62
    private let scrollBridge: ConversationPaneScrollBridge
    private let onUserFocus: () -> Void
    private let isActive: Bool

    init(
        pane: ConversationPaneController,
        runtime: ConversationRuntime,
        actionBridge: ComposerRuntimeActionBridge,
        maxProviderSteps: Int,
        isActive: Bool = true,
        usesSharedComposer: Bool = false, reservesSharedComposer: Bool = false,
        onUserFocus: @escaping () -> Void = {}
    ) {
        self.pane = pane
        self.runtime = runtime
        self.actionBridge = actionBridge
        self.maxProviderSteps = maxProviderSteps
        self.scrollBridge = pane.scrollBridge
        self.isActive = isActive
        self.usesSharedComposer = usesSharedComposer
        self.reservesSharedComposer = reservesSharedComposer
        self.onUserFocus = onUserFocus
    }

    private var bottomClearance: CGFloat {
        usesSharedComposer ? (reservesSharedComposer ? dock?.clearance ?? 62 : 0) : composerClearance
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
                    onUserFocus()
                    _ = pane.composer.addQuoteReference(reference)
                },
                onQuoteDragPhaseChanged: { phase in
                    _ = pane.composer.handle(.quoteDragPhaseChanged(phase))
                },
                onSelectionHandleDragChanged: { isDragging in
                    _ = pane.composer.handle(.selectionHandleDragChanged(isDragging))
                },
                onBlankBackgroundTap: {
                    if !isActive { onUserFocus(); return }
                    guard navigation?.blocksLift != true,
                          pane.composer.draft.presentationState == .editing,
                          pane.composer.quoteDragPhase == .idle,
                          !pane.composer.isSelectionHandleDragging else { return }
                    _ = pane.composer.handle(.conversationBackgroundTapped)
                },
                scrollBridge: scrollBridge,
                bottomComposerClearance: bottomClearance
            )
            .accessibilityIdentifier("conversation-pane-approval-\(pane.conversationID)")

            ConversationComposerView(
                conversationID: pane.conversationID,
                controller: pane.composer,
                bridge: actionBridge,
                maxProviderSteps: maxProviderSteps,
                coordinator: pane.session.sendCoordinator(bridge: actionBridge, maxProviderSteps: maxProviderSteps),
                onHeightChanged: { clearance in
                    guard abs(composerClearance - clearance) > 0.5 else { return }
                    scrollBridge.composerHeightWillChange()
                    composerClearance = clearance
                },
                onKeyboardWillChange: {
                    scrollBridge.composerKeyboardWillChange()
                },
                onUserFocus: onUserFocus
            )
            .environment(\.composerUsesWorkspaceDock, usesSharedComposer)
            .environment(\.composerIsActivePane, isActive)
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
                .padding(.bottom, bottomClearance + 24)
            }
        }
        .accessibilityIdentifier("conversation-pane-\(pane.conversationID)")
        .overlay(alignment: .bottom) {
            // Workspace notices share this Pane's keyboard-adjusted viewport
            // and the measured Composer clearance, including its quote shelf.
            bottomNotice
                .padding(.bottom, bottomClearance + 8)
        }
        .simultaneousGesture(TapGesture().onEnded {
            if !isActive, navigation?.blocksLift != true { onUserFocus() }
        })
        .onChange(of: bottomClearance) { _, _ in scrollBridge.composerHeightWillChange() }
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
