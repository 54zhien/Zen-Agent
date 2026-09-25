import SwiftUI

@MainActor
struct AppShellRootView: View {
    @State private var model = AppShellModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch model.launchState {
            case .notStarted, .loading:
                ProgressView("正在打开会话数据")
                    .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
            case .ready:
                NewConversationView(model: model)
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
    }
}

@MainActor
struct NewConversationView: View {
    let model: AppShellModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isProviderSetupPresented = false
    @State private var isRecentConversationsPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if model.canSend,
                   let pane = model.pane,
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
                        if model.canSend && !model.recentConversations.isEmpty {
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
                if let message = model.router.recoveryMessage(for: model.conversationID) {
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
                List(model.recentConversations) { conversation in
                    Button {
                        if model.openConversation(id: conversation.id) {
                            isRecentConversationsPresented = false
                        }
                    } label: {
                        Text(conversation.title)
                            .font(Typography.font(
                                for: .interfaceBody,
                                dynamicTypeSize: dynamicTypeSize
                            ))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recent-conversation-\(conversation.id)")
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
    }

}
