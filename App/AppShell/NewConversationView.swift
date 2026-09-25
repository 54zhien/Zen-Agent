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

    var body: some View {
        NavigationStack {
            Group {
                if model.canPresentCurrentPane,
                   let pane = model.pane,
                   let bridge = model.actionBridge,
                   let coordinator = model.composerSendCoordinator,
                   let runtime = model.runtimeForPresentation {
                    ConversationPaneView(
                        pane: pane,
                        runtime: runtime,
                        actionBridge: bridge,
                        sendCoordinator: coordinator,
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
                        .disabled(model.blocksConversationReplacement)
                        .accessibilityHint(
                            model.blocksConversationReplacement
                                ? "发送状态待确认，确认后可切换会话"
                                : ""
                        )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("配置模型") { isProviderSetupPresented = true }
                        .font(Typography.font(
                            for: .interfaceBody,
                            dynamicTypeSize: dynamicTypeSize
                        ))
                        .accessibilityIdentifier("new-conversation-configure")
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
                    ProviderSetupView(
                        model: providerSetup,
                        retryExistingTarget: { model.retryExistingTarget() }
                    )
                } else {
                    ProgressView()
                }
            }
        }
    }

}
