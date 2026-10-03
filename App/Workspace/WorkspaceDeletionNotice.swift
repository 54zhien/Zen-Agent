import SwiftUI
import UIKit

@MainActor
struct WorkspaceDeletionNotice: View {
    let model: AppShellModel
    let deletion: AppSpaceConversationDeletion
    let browse: AppSpaceBrowseController

    var body: some View {
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

}
