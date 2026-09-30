import SwiftUI

@MainActor
struct SplitEmptyPanePicker: View {
    let summaries: [RecentConversationSummary]
    let occupiedID: String
    let errorMessage: String?
    let hasMore: Bool
    let onLoadMore: () -> Void
    let onRetry: () -> Void
    let onOpen: (String) -> Void
    let onNew: () -> Void

    private var choices: [RecentConversationSummary] {
        Array(summaries.filter { $0.id != occupiedID }.reversed())
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择会话")
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.white)
                        Button("重试列表", action: onRetry)
                    }
                    if hasMore {
                        Button("更早的会话", action: onLoadMore)
                            .accessibilityIdentifier("split-history-more")
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(choices) { summary in
                                Button { onOpen(summary.id) } label: {
                                    Text(summary.title)
                                        .lineLimit(4)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                                               alignment: .topLeading)
                                        .padding(12)
                                }
                                .accessibilityIdentifier("split-history-\(summary.id)")
                                .frame(width: cardWidth(in: geometry), height: min(170, geometry.size.height * 0.55))
                                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
                            }
                            Button(action: onNew) {
                                Text("新会话")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: .topLeading)
                                    .padding(12)
                            }
                            .accessibilityIdentifier("split-new-conversation")
                            .frame(width: cardWidth(in: geometry), height: min(170, geometry.size.height * 0.55))
                            .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 18))
                            .id("split-new")
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .onAppear { reader.scrollTo("split-new", anchor: .trailing) }
            }
        }
        .background(Color(white: 0.09))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("split-empty-pane-picker")
    }

    private func cardWidth(in geometry: GeometryProxy) -> CGFloat {
        max(80, (geometry.size.width - 40) / 3)
    }
}

@MainActor
struct SplitSecondaryPaneView: View {
    let model: AppShellModel
    @Environment(\.surfaceLiftController) private var lift
    @State private var showsRecent = false
    @State private var selection: Task<Void, Never>?

    var body: some View {
        Group {
                if let pane = model.splitPane, let bridge = model.splitActionBridge,
                          let runtime = model.runtimeForPresentation {
                    NavigationStack {
                        ConversationPaneView(pane: pane, runtime: runtime, actionBridge: bridge,
                            maxProviderSteps: AppShellModel.maxProviderSteps,
                            isActive: model.splitWorkspace?.activeSlot == model.splitWorkspace?.emptySlot,
                            onUserFocus: {
                                if let split = model.splitWorkspace { model.selectSplitSlot(split.emptySlot) }
                            })
                            .navigationTitle("会话")
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("新会话") { _ = model.createNewInSplit() }
                                        .accessibilityIdentifier("split-secondary-new")
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button { showsRecent = true } label: { Image(systemName: "clock.arrow.circlepath") }
                                        .accessibilityLabel("最近会话")
                                        .accessibilityIdentifier("split-secondary-recent")
                                }
                            }
                    }
                    .id(pane.conversationID)
                }
        }
        .accessibilityIdentifier("split-secondary-pane")
        .sheet(isPresented: $showsRecent) {
            NavigationStack {
                List {
                    ForEach(model.recentConversations) { conversation in
                        Button(conversation.title) {
                            selection?.cancel()
                            selection = Task {
                                let opened = conversation.id == model.conversationID
                                    ? await model.openConversation(id: conversation.id)
                                    : await model.openInSplit(id: conversation.id)
                                if opened, !Task.isCancelled { showsRecent = false }
                            }
                        }
                        .accessibilityIdentifier("split-recent-\(conversation.id)")
                    }
                    if let error = model.splitOpenError ?? model.recentLoadError {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试列表") { model.retryRecentConversations() }
                    }
                    if model.recentHasMore {
                        Button("加载更多") { model.loadMoreRecentConversations() }
                    }
                }
                .navigationTitle("最近会话")
                .toolbar { Button("完成") { showsRecent = false } }
            }
        }
        .onChange(of: showsRecent) { _, presented in
            lift?.setOverlayPresented(presented)
            if !presented { selection?.cancel(); selection = nil }
        }
        .onChange(of: model.splitPane?.conversationID) { _, _ in
            guard !model.previewContent.isPresented, model.splitPane != nil else { return }
            if lift?.state.phase == .settling, lift?.state.pendingSettlement?.destination == .full { return }
            lift?.resetForConversationChange()
        }
        .onDisappear { selection?.cancel(); selection = nil }
    }
}
