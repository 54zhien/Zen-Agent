import Foundation
import Observation

@MainActor
@Observable
final class ConversationPreviewController {
    private enum SummaryFailure { case presentation, refresh }
    private var summaryFailure: SummaryFailure?
    private var returnFailed = false
    private(set) var summaries: [ConversationSummary] = []
    private(set) var isPresented = false
    private(set) var isPreparing = false
    @ObservationIgnored private(set) var session: ConversationSession?
    @ObservationIgnored private(set) var prepared: (pane: ConversationPaneController, bridge: ComposerRuntimeActionBridge)?
    @ObservationIgnored private var preparationID: UUID?

    var currentSummary: ConversationSummary? {
        summaries.first { $0.id == session?.conversationID }
    }

    var errorMessage: String? {
        if returnFailed { return "无法打开会话，轻点重试。" }
        guard let summaryFailure else { return nil }
        return switch summaryFailure {
        case .presentation: "无法读取预览，请重试。"
        case .refresh: "预览更新失败，轻点会话可重试打开。"
        }
    }

    var accessibilityLabel: String {
        let statusLabel: String? = switch status {
        case .restoring: "正在打开会话"
        case .contentUnavailable: "部分内容暂不可用"
        case .failed(let message): message
        case .ready, .migrationRequired: nil
        }
        return [currentSummary?.title ?? "新会话",
         ConversationCardStatus.derive(from: currentSummary?.runProjection)?.label,
         statusLabel, "轻点返回会话"].compactMap { $0 }.joined(separator: "，")
    }

    var status: ConversationPreviewStatus {
        if isPreparing { return .restoring }
        if let errorMessage { return .failed(errorMessage) }
        return currentSummary?.contentUnavailable == true ? .contentUnavailable : .ready
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
            self.session = session
            summaryFailure = nil
            returnFailed = false
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

    func beginPreparation() -> UUID {
        let id = UUID()
        preparationID = id
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
        returnFailed = false
    }

    func failed(_ id: UUID) {
        guard accepts(id) else { return }
        preparationID = nil
        isPreparing = false
        returnFailed = true
    }

    func cancelPreparation(for id: UUID? = nil) {
        if let id, !accepts(id) { return }
        preparationID = nil
        isPreparing = false
        prepared = nil
    }

    func finish() {
        cancelPreparation()
        isPresented = false
        session = nil
        summaries = []
        summaryFailure = nil
        returnFailed = false
    }
}
