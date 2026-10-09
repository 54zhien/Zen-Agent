import Foundation
import Observation

@MainActor
@Observable
final class ConversationPreviewController {
    private enum SummaryFailure { case presentation, refresh }
    private struct ReturnFailure { let targetID: String? }
    private var summaryFailure: SummaryFailure?
    private var returnFailure: ReturnFailure?
    private(set) var summaries: [ConversationSummary] = []
    private(set) var isPresented = false
    private(set) var isPreparing = false
    private(set) var preparationTargetID: String?
    private(set) var originID: String?
    @ObservationIgnored private(set) var session: ConversationSession?
    @ObservationIgnored private(set) var prepared: (pane: ConversationPaneController, bridge: ComposerRuntimeActionBridge)?
    @ObservationIgnored private var preparationID: UUID?

    var currentSummary: ConversationSummary? {
        summaries.first { $0.id == originID }
    }

    var errorMessage: String? {
        if returnFailure != nil { return "无法打开会话，轻点重试。" }
        guard let summaryFailure else { return nil }
        return switch summaryFailure {
        case .presentation: "无法读取预览，请重试。"
        case .refresh: "预览更新失败，轻点会话可重试打开。"
        }
    }

    var accessibilityLabel: String {
        Self.accessibilityLabel(summary: currentSummary, status: status)
    }

    static func accessibilityLabel(summary: ConversationSummary?, status: ConversationPreviewStatus) -> String {
        let statusLabel: String? = switch status {
        case .restoring: "正在打开会话"
        case .contentUnavailable: "部分内容暂不可用"
        case .failed(let message): message
        case .ready, .migrationRequired: nil
        }
        return [summary?.title ?? "新会话",
         ConversationCardStatus.derive(from: summary?.runProjection)?.label,
         statusLabel, "轻点返回会话"].compactMap { $0 }.joined(separator: "，")
    }

    var status: ConversationPreviewStatus {
        if isPreparing { return .restoring }
        if let errorMessage { return .failed(errorMessage) }
        return currentSummary?.contentUnavailable == true ? .contentUnavailable : .ready
    }

    func status(for targetID: String?, summary: ConversationSummary?, summaryError: String? = nil) -> ConversationPreviewStatus {
        if isPreparing, preparationTargetID == targetID { return .restoring }
        if let returnFailure, returnFailure.targetID == targetID {
            return .failed("无法打开会话，轻点重试。")
        }
        if let summaryError { return .failed(summaryError) }
        if summaryFailure != nil {
            return .failed("预览更新失败，轻点会话可重试打开。")
        }
        return summary?.contentUnavailable == true ? .contentUnavailable : .ready
    }

    func releaseSummaryWindow() {
        // Workspace Browse owns the one bounded projection window. Preview keeps
        // the original warm owner and Return facts, not a second history window.
        summaries = []
    }

    func discardFinalizedOriginSession(id: String) {
        guard isPresented, originID == id else { return }
        // Keep only the scalar origin identity for an in-flight Return. The
        // deleted Conversation's draft and reading state must leave memory.
        session = nil
        summaries.removeAll { $0.id == id }
    }

    func present(session: ConversationSession, store: PersistenceStore) -> Bool {
        do {
            let current = try store.conversationSummaryWindow(ids: [session.conversationID]).first
            // A missing row is a legitimate new page, but a deleted row is not.
            if current == nil, try store.conversationLifecycle(id: session.conversationID) != nil {
                throw AppTargetFailure.persistenceUnavailable
            }
            let predecessors = try store.conversationSummaryPage(limit: 3, after: current?.cursor).items
            summaries = (current.map { [$0] } ?? []) + predecessors
            originID = session.conversationID
            self.session = session
            summaryFailure = nil
            returnFailure = nil
            isPresented = true
            return true
        } catch {
            summaryFailure = .presentation
            return false
        }
    }

    func refresh(store: PersistenceStore) {
        guard isPresented, let session else { return }
        do {
            // A new page may become durable while its editor is detached. Always
            // acquire the current ID; retain only the existing bounded predecessors.
            let predecessors = summaries.filter { $0.id != session.conversationID }.prefix(3).map(\.id)
            summaries = try store.conversationSummaryWindow(ids: [session.conversationID] + predecessors)
            summaryFailure = nil
        } catch {
            // Keep the last readable projection. Refresh must not erase a Return failure.
            summaryFailure = .refresh
        }
    }

    func beginPreparation(targetID: String? = nil) -> UUID {
        let id = UUID()
        preparationID = id
        preparationTargetID = targetID ?? session?.conversationID
        isPreparing = true
        // Retain a prior failure through cancellation; restoring owns its display
        // while this operation is pending, and accepted success clears its source.
        return id
    }

    func accepts(_ id: UUID) -> Bool { isPresented && preparationID == id }

    func ready(_ wiring: (bridge: ComposerRuntimeActionBridge, pane: ConversationPaneController), id: UUID) {
        guard accepts(id) else { return }
        prepared = (wiring.pane, wiring.bridge)
        isPreparing = false
        returnFailure = nil
    }

    func failed(_ id: UUID) {
        guard accepts(id) else { return }
        preparationID = nil
        isPreparing = false
        returnFailure = ReturnFailure(targetID: preparationTargetID)
    }

    func cancelPreparation(for id: UUID? = nil) {
        if let id, !accepts(id) { return }
        preparationID = nil
        preparationTargetID = nil
        isPreparing = false
        prepared = nil
    }

    func finish() {
        cancelPreparation()
        isPresented = false
        originID = nil
        session = nil
        summaries = []
        summaryFailure = nil
        returnFailure = nil
    }
}
