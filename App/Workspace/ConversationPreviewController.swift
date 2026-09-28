import Foundation
import Observation

@MainActor
@Observable
final class ConversationPreviewController {
    private(set) var summaries: [ConversationSummary] = []
    private(set) var isPresented = false
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    @ObservationIgnored private(set) var session: ConversationSession?
    @ObservationIgnored private(set) var prepared: (pane: ConversationPaneController, bridge: ComposerRuntimeActionBridge)?
    @ObservationIgnored private var preparationID: UUID?

    var status: ConversationPreviewStatus {
        if let errorMessage { return .failed(errorMessage) }
        if isPreparing { return .restoring }
        return summaries.first?.contentUnavailable == true ? .contentUnavailable : .ready
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
            errorMessage = nil
            isPresented = true
            return true
        } catch {
            errorMessage = "无法读取预览，请重试。"
            return false
        }
    }

    func refresh(store: PersistenceStore) {
        guard isPresented else { return }
        do {
            summaries = try store.conversationSummaryWindow(ids: summaries.map(\.id))
        } catch {
            // Keep the last readable projection. Refresh must not erase a Return failure.
            errorMessage = "预览更新失败，轻点会话可重试打开。"
        }
    }

    func beginPreparation() -> UUID {
        let id = UUID()
        preparationID = id
        isPreparing = true
        errorMessage = nil
        return id
    }

    func accepts(_ id: UUID) -> Bool { isPresented && preparationID == id }

    func ready(_ wiring: (bridge: ComposerRuntimeActionBridge, pane: ConversationPaneController), id: UUID) {
        guard accepts(id) else { return }
        prepared = (wiring.pane, wiring.bridge)
        isPreparing = false
    }

    func failed(_ id: UUID) {
        guard accepts(id) else { return }
        preparationID = nil
        isPreparing = false
        errorMessage = "无法打开会话，轻点重试。"
    }

    func cancelPreparation() {
        preparationID = nil
        isPreparing = false
        prepared = nil
    }

    func finish() {
        cancelPreparation()
        isPresented = false
        session = nil
        summaries = []
        errorMessage = nil
    }
}
