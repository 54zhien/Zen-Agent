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
                WorkspaceSurfaceView(model: model) {
                    NewConversationView(model: model)
                }
                .ignoresSafeArea()
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isProviderSetupPresented = false
    @State private var isRecentConversationsPresented = false
    @State private var historyAction: Task<Void, Never>?
    @Environment(\.surfaceLiftController) private var lift

    var body: some View {
        Group {
            if model.previewContent.isPresented {
                ConversationPreviewView(
                    summary: model.previewContent.summaries.first { $0.id == model.conversationID },
                    status: model.previewContent.status)
            } else {
                fullContent
            }
        }
        .onChange(of: model.conversationID) { _, _ in lift?.resetForConversationChange() }
        .onChange(of: model.previewContent.isPresented) { _, presented in
            // Directly opening the current Card has no identity change. Normal
            // animated Return is already settling and must finish its late segment.
            if !presented, lift?.state.phase == .card { lift?.resetForConversationChange() }
        }
    }

    private var fullContent: some View {
        NavigationStack {
            Group {
                if let pane = model.pane,
                   let bridge = model.actionBridge,
                   let runtime = model.runtimeForPresentation {
                    ConversationPaneView(
                        pane: pane,
                        runtime: runtime,
                        actionBridge: bridge,
                        maxProviderSteps: AppShellModel.maxProviderSteps
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
                        Button("配置模型") { isProviderSetupPresented = true }
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                    }
                }
            }
            .navigationTitle("新会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("新会话") { model.newConversation() }
                        .font(Typography.font(
                            for: .interfaceBody,
                            dynamicTypeSize: dynamicTypeSize
                        ))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !model.recentConversations.isEmpty || model.recentLoadError != nil {
                            Button {
                                isRecentConversationsPresented = true
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                            .accessibilityLabel("最近会话")
                            .accessibilityIdentifier("new-conversation-recent")
                        }

                        Button("配置模型") { isProviderSetupPresented = true }
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                            .accessibilityIdentifier("new-conversation-configure")
                    }
                }
            }
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
                } else if let message = model.router.recoveryMessage(for: model.conversationID) {
                    HStack(spacing: 12) {
                        Text(message)
                            .font(Typography.font(
                                for: .interfaceCaption,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                        Button("重试加载") {
                            historyAction?.cancel()
                            historyAction = Task {
                                _ = await model.router.retryTimelineLoad(for: model.conversationID)
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
                        .accessibilityIdentifier("recent-conversation-\(conversation.id)")
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

    }

    private func openRecentConversation(id: String) {
        historyAction?.cancel()
        historyAction = Task {
            let opened = await model.openConversation(id: id)
            guard !Task.isCancelled, isRecentConversationsPresented else { return }
            if opened {
                isRecentConversationsPresented = false
            } else if let failure = model.recentOpenFailure, failure.conversationID == id {
                UIAccessibility.post(notification: .announcement, argument: failure.message)
            }
        }
    }

}
