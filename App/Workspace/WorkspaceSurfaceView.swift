import SwiftUI
import UIKit

private struct SurfaceLiftControllerKey: EnvironmentKey {
    static let defaultValue: SurfaceLiftController? = nil
}

private struct SurfaceBrowseControllerKey: EnvironmentKey {
    static let defaultValue: AppSpaceBrowseController? = nil
}

extension EnvironmentValues {
    var surfaceLiftController: SurfaceLiftController? {
        get { self[SurfaceLiftControllerKey.self] }
        set { self[SurfaceLiftControllerKey.self] = newValue }
    }
    var surfaceBrowseController: AppSpaceBrowseController? {
        get { self[SurfaceBrowseControllerKey.self] }
        set { self[SurfaceBrowseControllerKey.self] = newValue }
    }
}

@MainActor
struct WorkspaceSurfaceView<Content: View>: View {
    let content: Content
    private let model: AppShellModel?
    @State private var lift: SurfaceLiftController
    @State private var browse = AppSpaceBrowseController()
    @State private var requestedMenuID: String?
    @ScaledMetric(relativeTo: .body) private var minimumWidth = 220.0
    @ScaledMetric(relativeTo: .body) private var minimumHeight = 300.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: AppShellModel? = nil, liftController: SurfaceLiftController = SurfaceLiftController(),
         @ViewBuilder content: () -> Content) {
        _lift = State(initialValue: liftController)
        self.model = model
        self.content = content()
    }

    private var deleteAction: AppSpaceCardDeletionInteraction.Commit? {
        guard let model else { return nil }
        return { id, stillSelected in
            await model.deleteAppSpaceConversation(id: id, stillSelected: {
                model.previewContent.isPresented && lift.state.phase == .card && stillSelected()
            })
        }
    }

    private var isDeletionPending: (@MainActor (String) -> Bool)? {
        guard let model else { return nil }
        return { id in model.cardDeletion?.pendingCards.contains { $0.conversationID == id } == true }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.035)
            if model?.previewContent.isPresented == true, let layout = browse.layout() {
                ForEach(layout.cards.filter { $0.item != browse.state.selected }
                    .map { browse.deletionProjection($0, in: layout) }, id: \.item) { card in
                    projectedCard(card)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .opacity(card.opacity)
                        .position(x: card.frame.midX, y: card.frame.midY)
                        .zIndex(4 - card.depth)
                }
            }
            ConversationSurfaceHost(liftController: lift, browseController: model == nil ? nil : browse,
                                    deleteAction: deleteAction, isDeletionPending: isDeletionPending) {
                content.environment(\.surfaceLiftController, lift)
                    .environment(\.surfaceBrowseController, model == nil ? nil : browse)
            }
            .zIndex(4 - (browse.layout()?.cards.first { $0.item == browse.state.selected }?.depth ?? 0))
            if lift.splitTargetingVisible, let top = lift.splitTopFrame,
               let bottom = lift.splitBottomFrame, let guide = lift.splitGuideFrame {
                splitTargetOverlay(top: top, bottom: bottom, guide: guide)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(50)
            }
            if let model, model.previewContent.isPresented, !browse.isNewEntry, browse.canEditCurrentMetadata,
               let summary = browse.currentSummary,
               let frame = browse.layout()?.cards.first(where: { $0.item == browse.state.selected })?.frame {
                AppSpaceCardActionsView(model: model, browse: browse, lift: lift,
                    summary: summary, requestedID: $requestedMenuID)
                    .position(x: frame.maxX - 24, y: frame.minY + 24)
                    .zIndex(100)
            }
            if let model, let deletion = model.cardDeletion,
               !deletion.pendingCards.isEmpty || deletion.errorMessage != nil {
                deletionBanner(model: model, deletion: deletion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 36)
                    .zIndex(200)
            }
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1"
                || ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                SurfaceLiftStateProbe(phase: lift.state.phase)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                SplitDropIntentProbe(slot: lift.lastSplitDropIntent?.slot)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
#endif
        }
        .ignoresSafeArea()
        .onAppear {
            if let model {
                let browseController = browse
                browse.configure(reader: { [weak model] id in
                    guard let model else { throw PersistenceError.conversationNotFound(id) }
                    return try model.browseWindow(id: id)
                })
                browse.configureNewEntry(reader: { [weak model] in
                    guard let model else { throw AppTargetFailure.persistenceUnavailable }
                    return try model.newConversationBrowseWindow()
                })
                let menuRequest = $requestedMenuID
                browse.onOpenActions = { [weak browseController, weak model] in
                    guard let browseController, let model, model.previewContent.isPresented,
                          !model.previewContent.isPreparing, !browseController.isNewEntry,
                          browseController.canEditCurrentMetadata,
                          let id = browseController.currentSummary?.id else { return false }
                    menuRequest.wrappedValue = id
                    return true
                }
                lift.configurePreview(
                    enter: { [weak model, weak browseController] in
                        guard let model, let browseController, model.enterPreview() else { return false }
                        browseController.present(originID: model.conversationID, fallback: model.previewContent.summaries)
                        model.previewContent.releaseSummaryWindow()
                        return true
                    },
                    prepare: { [weak model, weak browseController] in
                        guard let model, let browseController else { return false }
                        browseController.cancel()
                        if browseController.isNewEntry {
                            do {
                                let id = try model.createConversationFromAppSpace()
                                guard browseController.selectCreatedConversation(id: id) else { return false }
                                model.acknowledgeAppSpaceCreation(id: id)
                            } catch { return false }
                        }
                        return await model.preparePreviewReturn(to: browseController.selectedConversationID)
                    },
                    commit: { [weak model] in model?.commitPreviewReturn() ?? false },
                    cancel: { [weak model] in model?.cancelPreviewReturn() },
                    isPresented: { [weak model] in model?.previewContent.isPresented ?? false },
                    label: { [weak model, weak browseController] in
                        guard let model, let browseController else { return "当前会话" }
                        return Self.cardLabel(model: model, browse: browseController)
                    })
                if model.previewContent.isPresented {
                    browse.present(originID: model.conversationID, fallback: model.previewContent.summaries)
                    model.previewContent.releaseSummaryWindow()
                }
            }
            updateMinimumSize()
        }
        .task(id: model?.previewContent.isPresented) {
            guard let model, model.previewContent.isPresented else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard model.previewContent.isPresented else { return }
                if !model.previewContent.isPreparing { browse.refresh() }
            }
        }
        .onChange(of: cardLabel) { _, _ in lift.refreshCardAccessibility() }
        .onChange(of: model?.previewContent.isPresented) { _, presented in
            if presented != true { browse.finish() }
        }
        .onChange(of: dynamicTypeSize) { _, _ in updateMinimumSize() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { browse.cancel(); lift.invalidate() }
        }
    }

    private var cardLabel: String {
        guard let model else { return "当前会话" }
        return Self.cardLabel(model: model, browse: browse)
    }

    private func splitTargetOverlay(top: CGRect, bottom: CGRect, guide: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            zone(top, selected: lift.splitTargetSlot == .top)
            zone(bottom, selected: lift.splitTargetSlot == .bottom)
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: min(64, guide.width * 0.2), height: guide.height)
                .position(x: guide.midX, y: guide.midY)
        }
    }

    private func zone(_ frame: CGRect, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.09), lineWidth: selected ? 1.5 : 1)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.07 : 0.025)))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func deletionBanner(model: AppShellModel,
                                deletion: AppSpaceConversationDeletion) -> some View {
        VStack(spacing: 6) {
            if let error = deletion.errorMessage {
                HStack(spacing: 12) {
                    Text(error).font(.footnote)
                    if deletion.needsRecoveryRetry {
                        Button("重试") { deletion.recoverPending() }
                            .accessibilityIdentifier("workspace-card-recovery-retry")
                    } else {
                        Button("关闭") { deletion.clearError() }
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if !deletion.pendingCards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(deletion.pendingCards, id: \.conversationID) { item in
                            HStack(spacing: 12) {
                                Text(deletion.needsRecoveryDecision(conversationID: item.conversationID)
                                    ? "删除待确认" : "会话已删除").font(.footnote)
                                if deletion.needsRecoveryDecision(conversationID: item.conversationID) {
                                    Button("保留会话") {
                                        if model.restoreRecoveredAppSpaceConversation(id: item.conversationID) {
                                            if browse.isPresented {
                                                _ = browse.selectRestoredConversation(id: item.conversationID)
                                            }
                                            UIAccessibility.post(notification: .announcement,
                                                argument: "会话已保留")
                                        }
                                    }
                                    .accessibilityIdentifier("workspace-card-restore-\(item.conversationID)")
                                    Button("确认删除", role: .destructive) {
                                        _ = model.confirmRecoveredAppSpaceConversationDeletion(id: item.conversationID)
                                    }
                                    .accessibilityIdentifier("workspace-card-confirm-delete-\(item.conversationID)")
                                } else if deletion.canUndo(conversationID: item.conversationID) {
                                    Button("撤销") {
                                        if model.undoAppSpaceConversation(id: item.conversationID) {
                                            if browse.isPresented {
                                                _ = browse.selectRestoredConversation(id: item.conversationID)
                                            }
                                            UIAccessibility.post(notification: .announcement,
                                                argument: "会话已恢复")
                                        }
                                    }
                                    .accessibilityIdentifier("workspace-card-undo-\(item.conversationID)")
                                } else {
                                    Button("重试清理") {
                                        deletion.retryFinalization(conversationID: item.conversationID)
                                    }
                                    .accessibilityIdentifier("workspace-card-cleanup-\(item.conversationID)")
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 54)
            }
        }
    }

    private static func cardLabel(model: AppShellModel, browse: AppSpaceBrowseController) -> String {
        if browse.isNewEntry {
            return ["新对话", model.appSpaceActionError(for: nil) ?? browse.errorMessage, "创建新对话"].compactMap { $0 }.joined(separator: "，")
        }
        if browse.currentSummary == nil { return "未发送的会话，轻点返回会话" }
        let status = model.previewContent.status(for: browse.selectedConversationID,
            summary: browse.currentSummary, summaryError: model.appSpaceActionError(for: browse.selectedConversationID) ?? browse.errorMessage)
        return ConversationPreviewController.accessibilityLabel(summary: browse.currentSummary, status: status)
    }

    private func projectedCard(_ card: AppSpaceBrowseGeometry.Card) -> some View {
        let summary: ConversationSummary? = {
            if case .conversation(let id) = card.item { return browse.summaries.first { $0.id == id } }
            return nil
        }()
        let size = browse.viewportSize
        let insets = browse.safeArea
        let pose = AppSpaceBrowseGeometry.pose(for: card, size: size, safeArea: insets)
        // Match the native Current's logical viewport, scaling and crop. Reflowing
        // a predecessor at its thumbnail width would jump its text at commitment.
        return ConversationPreviewView(summary: summary,
            status: summary?.contentUnavailable == true ? .contentUnavailable : .ready,
            isNewEntry: browse.supportsNewEntry && card.item == .newConversation)
            .frame(width: max(1, size.width - insets.left - insets.right),
                height: max(1, size.height - insets.top - insets.bottom))
            .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
            .scaleEffect(pose?.scale ?? 1)
            .frame(width: card.frame.width, height: card.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous))
    }

    private func updateMinimumSize() {
        browse.updateMinimumCardSize(CGSize(width: minimumWidth, height: minimumHeight))
        lift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        lift.invalidate()
    }
}

#if DEBUG
private struct SurfaceLiftStateProbe: UIViewRepresentable {
    let phase: SurfaceLiftState.Phase
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "surface-lift-state-probe"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = String(describing: phase)
    }
}

private struct SplitDropIntentProbe: UIViewRepresentable {
    let slot: SplitDropSlot?
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "split-drop-intent-probe"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = slot?.rawValue ?? "none"
    }
}

@MainActor
struct SurfaceLiftUITestFixture: View {
    var body: some View {
        WorkspaceSurfaceView { ConversationPaneReadingUITestFixtureView() }
    }
}
#endif
