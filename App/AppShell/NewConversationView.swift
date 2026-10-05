import SwiftUI
import UIKit

@MainActor
struct AppShellRootView: View {
    let model: AppShellModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.launchState {
            case .notStarted, .loading:
                ProgressView("正在打开会话数据")
                    .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
            case .ready:
                WorkspaceSurfaceView(model: model, contentForSlot: { slot in
                    NewConversationView(model: model, surfaceSlot: slot)
                })
                .ignoresSafeArea(.container)
            case .failed(let failure):
                VStack(spacing: 16) {
                    Text(failure.title)
                        .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                    Text(failure.summary)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("重试") { model.assemble() }
                        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                }
                .padding()
            }
        }
        .task {
            model.assembleIfNeeded()
        }
        .preferredColorScheme(model.appearance.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.enteredBackground(at: Date())
            case .active:
                model.becameActive(at: Date())
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

@MainActor
struct NewConversationView: View {
    let model: AppShellModel
    var surfaceSlot: WorkspaceSurfaceSlot = .primary

    private var isSource: Bool { surfaceSlot == model.sourceSurfaceSlot }
    private var presentedPane: ConversationPaneController? { isSource ? model.pane : model.splitPane }
    private var presentedBridge: ComposerRuntimeActionBridge? { isSource ? model.actionBridge : model.splitActionBridge }
    private var presentedID: String { presentedPane?.conversationID ?? model.conversationID }
    private var logicalSlot: SplitDropSlot? {
        guard let split = model.splitWorkspace else { return nil }
        return isSource ? split.sourceSlot : split.emptySlot
    }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isProviderSetupPresented = false
    @State private var isRecentConversationsPresented = false
    @State private var historyAction: Task<Void, Never>?
    @Environment(\.surfaceLiftController) private var lift
    @Environment(\.surfaceBrowseController) private var browse
    @Environment(\.workspaceNavigation) private var workspaceNavigation
    @Environment(\.workspaceComposerDock) private var composerDock

    var body: some View {
        Group {
            if model.previewContent.isPresented,
               model.previewSurfaceSlot == surfaceSlot {
                ConversationPreviewView(
                    summary: browse?.isPresented == true ? browse?.currentSummary : model.previewContent.currentSummary,
                    status: model.appSpaceActionError(for: browse?.selectedConversationID).map { .failed($0) } ?? (browse?.isPresented == true
                        ? model.previewContent.status(for: browse?.selectedConversationID,
                            summary: browse?.currentSummary, summaryError: browse?.errorMessage)
                        : model.previewContent.status),
                    isNewEntry: browse?.isNewEntry == true)
            } else {
                fullContent
            }
        }
        .accessibilityIdentifier(isSource ? "workspace-source-pane" : "split-secondary-pane")
        .onChange(of: presentedID) { _, _ in
            // Selected Full commits at the existing late handoff. Cancelling here
            // would interrupt the second segment of that same Surface.
            if lift?.state.phase == .settling, lift?.state.pendingSettlement?.destination == .full,
               model.previewHandoffID == presentedID { return }
            lift?.resetForConversationChange()
        }
        .onChange(of: model.previewContent.isPresented) { _, presented in
            // Directly opening the current Card has no identity change. Normal
            // animated Return is already settling and must finish its late segment.
            if !presented, lift?.state.phase == .card { lift?.resetForConversationChange() }
        }
    }

    private var fullContent: some View {
        NavigationStack {
            Group {
                if let pane = presentedPane,
                   let bridge = presentedBridge,
                   let runtime = model.runtimeForPresentation {
                    ConversationPaneView(
                        pane: pane,
                        runtime: runtime,
                        actionBridge: bridge,
                        maxProviderSteps: AppShellModel.maxProviderSteps,
                        isActive: isActivePane,
                        usesSharedComposer: model.splitWorkspace != nil,
                        reservesSharedComposer: reservesSharedComposer,
                        onUserFocus: {
                            guard lift?.state.phase == .full, lift?.workspaceResizeActive != true,
                                  workspaceNavigation?.blocksLift != true else { return }
                            if let logicalSlot { model.selectSplitSlot(logicalSlot) }
                        }
                    )
                    // Native scroll geometry belongs to this Conversation's Pane.
                    // Async Open must not reuse the outgoing empty page's measurements.
                    .id(pane.conversationID)
                } else {
                    ContentUnavailableView {
                        Label("新会话", systemImage: "bubble.left")
                            .font(Typography.font(
                                for: .interfaceTitle,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                    } description: {
                        Text(model.targetMessage ?? "请先配置模型")
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                    } actions: {
                        Text("从屏幕左边缘滑出侧边栏，在设置中配置模型。")
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let message = model.previewContent.errorMessage {
                    Text(message)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                        .padding()
                        .background(.regularMaterial)
                } else if let message = model.coldStartRecoveryMessage {
                    HStack(spacing: 12) {
                        Text(message)
                        Button("重试恢复") { model.retryColdStartRecovery() }
                    }
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                    .padding()
                    .background(.regularMaterial)
                } else if let message = model.router.recoveryMessage(for: presentedID) {
                    HStack(spacing: 12) {
                        Text(message)
                            .font(Typography.font(
                                for: .interfaceCaption,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                        Button("重试加载") {
                            historyAction?.cancel()
                            historyAction = Task {
                                _ = await model.router.retryTimelineLoad(for: presentedID)
                            }
                        }
                        .font(Typography.font(
                            for: .interfaceCaption,
                            dynamicTypeSize: dynamicTypeSize
                        ))
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .sheet(isPresented: $isProviderSetupPresented) {
                if let providerSetup = model.providerSetup {
                    ProviderSetupView(model: providerSetup)
                } else {
                    ProgressView()
                }
            }
            .onChange(of: model.persistedTurnCount) { previousCount, currentCount in
                guard currentCount > previousCount else { return }
                model.refreshRecentConversations()
            }
        }
        .sheet(isPresented: $isRecentConversationsPresented) {
            NavigationStack {
                List {
                    ForEach(model.recentConversations) { conversation in
                        Button {
                            openRecentConversation(id: conversation.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .lineLimit(2)
                                if conversation.previewStatus == .contentUnavailable {
                                    Text("部分内容暂不可用")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(isSource ? "recent-conversation-\(conversation.id)" : "split-recent-\(conversation.id)")
                    }
                    if let error = model.recentLoadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .foregroundStyle(.secondary)
                            if let failure = model.recentOpenFailure {
                                Button("重试打开") { openRecentConversation(id: failure.conversationID) }
                                    .accessibilityIdentifier("recent-conversation-open-retry")
                            } else {
                                Button("重试") { model.retryRecentConversations() }
                                    .accessibilityIdentifier("recent-conversations-retry")
                            }
                        }
                        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                    } else if model.recentHasMore {
                        Button("加载更多") { model.loadMoreRecentConversations() }
                            .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                            .accessibilityIdentifier("recent-conversations-more")
                    }
                }
                .listStyle(.plain)
                .navigationTitle("最近会话")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isRecentConversationsPresented = false }
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                    }
                }
            }
        }
        .onChange(of: isProviderSetupPresented || isRecentConversationsPresented) { _, presented in
            lift?.setOverlayPresented(presented)
        }
        .onChange(of: isRecentConversationsPresented) { _, presented in
            if !presented { historyAction?.cancel(); historyAction = nil }
        }
        .onDisappear { historyAction?.cancel(); historyAction = nil }
        .onAppear { publishSidebarActions() }
        .onChange(of: isActivePane ? presentedID : nil) { _, _ in publishSidebarActions() }
        .onChange(of: sidebarActions) { _, _ in publishSidebarActions() }

    }

    private var isActivePane: Bool {
        model.splitWorkspace == nil ? isSource : model.splitWorkspace?.activeSlot == logicalSlot
    }
    private var reservesSharedComposer: Bool {
        let landscapeSingle = composerDock.map { !$0.isPad && $0.windowSize.width > $0.windowSize.height } ?? false
        return landscapeSingle || model.splitWorkspace?.axis == .leftRight || logicalSlot == .bottom
    }
    private var sidebarActions: Set<WorkspaceConversationAction> {
        var result: Set<WorkspaceConversationAction> = [.new]
        if !model.recentConversations.isEmpty || model.recentLoadError != nil { result.insert(.recent) }
        if model.splitWorkspace == nil, canOpenAccessibleSplit { result.formUnion([.splitTop, .splitBottom]) }
        if isSource, model.currentSettingsNewID == presentedID { result.insert(.configure) }
        return result
    }
    private func publishSidebarActions() {
        guard isActivePane, let workspaceNavigation else { return }
        let ownerID = presentedID
        workspaceNavigation.conversationActions = sidebarActions
        workspaceNavigation.onConversationAction = { action in
            guard isActivePane, presentedID == ownerID, !model.previewContent.isPresented else { return }
            switch action {
            case .new:
                if isSource { model.newConversation() } else { _ = model.createNewInSplit() }
            case .recent: isRecentConversationsPresented = true
            case .splitTop: openAccessibleSplit(.top)
            case .splitBottom: openAccessibleSplit(.bottom)
            case .configure: configureNew()
            }
        }
    }

    private func configureNew() {
        if let workspaceNavigation { workspaceNavigation.onConfigureNew?(presentedID) }
        else { isProviderSetupPresented = true }
    }

    private func openRecentConversation(id: String) {
        historyAction?.cancel()
        historyAction = Task {
            let opened = isSource || id == model.conversationID
                ? await model.openConversation(id: id) : await model.openInSplit(id: id)
            guard !Task.isCancelled, isRecentConversationsPresented else { return }
            if opened {
                isRecentConversationsPresented = false
            } else if let failure = model.recentOpenFailure, failure.conversationID == id {
                UIAccessibility.post(notification: .announcement, argument: failure.message)
            }
        }
    }

    private var canOpenAccessibleSplit: Bool {
        guard let pane = model.pane, lift?.state.phase == .full else { return false }
        return pane.composer.canBeginSurfaceLift(
            keyboardVisible: pane.composer.draft.presentationState == .editing,
            stableBottomAnchor: true)
    }

    private func openAccessibleSplit(_ slot: SplitDropSlot) {
        guard canOpenAccessibleSplit else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            _ = model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: slot))
        }
    }

}
