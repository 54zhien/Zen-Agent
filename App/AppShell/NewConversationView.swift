import SwiftUI

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
                WorkspaceSurfaceView {
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
    @Environment(\.surfaceLiftController) private var lift

    var body: some View {
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
                if let message = model.coldStartRecoveryMessage {
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
                            _ = model.router.retryTimelineLoad(for: model.conversationID)
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
                            if model.openConversation(id: conversation.id) {
                                isRecentConversationsPresented = false
                            }
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
                            Button("重试") { model.retryRecentConversations() }
                                .accessibilityIdentifier("recent-conversations-retry")
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
        .onChange(of: model.conversationID) { _, _ in lift?.invalidate() }
    }

}
