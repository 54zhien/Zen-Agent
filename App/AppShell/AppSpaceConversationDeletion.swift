import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceConversationDeletion {
    typealias RunAction = @MainActor (String) async throws -> Void

    private(set) var pendingCards: [PendingCardDeletion] = []
    var pending: PendingCardDeletion? { pendingCards.last }
    private(set) var errorMessage: String?
    private(set) var needsRecoveryRetry = false
    private(set) var recoveryDecisionIDs: Set<String> = []
    private(set) var isDeleting = false

    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let stopRun: RunAction
    @ObservationIgnored private let waitForRun: RunAction
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let onFinalized: @MainActor (String) -> Void
    @ObservationIgnored private var expiryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var awaitingMonotonicExpiryIDs: Set<String> = []

    init(store: PersistenceStore, stopRun: @escaping RunAction,
         waitForRun: @escaping RunAction, now: @escaping @MainActor () -> Date,
         onFinalized: @escaping @MainActor (String) -> Void = { _ in }) {
        self.store = store
        self.stopRun = stopRun
        self.waitForRun = waitForRun
        self.now = now
        self.onFinalized = onFinalized
    }

    func delete(conversationID: String, stillSelected: @MainActor () -> Bool) async -> Bool {
        guard !isDeleting, stillSelected() else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            guard try store.conversationLifecycle(id: conversationID) == .visible else {
                throw PersistenceError.invalidTransition("Only a visible Conversation can be deleted")
            }
            for run in try store.activeParentRuns(inConversation: conversationID) {
                // stop() requests cancellation; waitForCompletion() is the durable
                // boundary at which the active slot has actually been released.
                try await stopRun(run.id)
                try await waitForRun(run.id)
                guard let settled = try store.run(id: run.id), settled.state == .cancelled else {
                    throw PersistenceError.invalidTransition("Parent Run did not cancel")
                }
            }
            guard !Task.isCancelled, stillSelected() else { return false }
            let committed = try store.beginCardDeletion(conversationID: conversationID, at: now())
            addPending(committed)
            scheduleExpiry(for: committed)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "无法删除会话，原卡片已保留。请重试。"
            return false
        }
    }

    @discardableResult
    func undo(conversationID: String) -> Bool {
        guard canUndo(conversationID: conversationID) else {
            errorMessage = "撤销窗口已结束，请检查会话的恢复选项。"
            return false
        }
        do {
            try store.restoreCardDeletionWithoutWallDeadline(conversationID: conversationID, at: now())
            clearPending(conversationID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "撤销未完成，请检查会话状态或重试。"
            return false
        }
    }

    func canUndo(conversationID: String) -> Bool {
        awaitingMonotonicExpiryIDs.contains(conversationID)
            && !recoveryDecisionIDs.contains(conversationID)
    }

    func needsRecoveryDecision(conversationID: String) -> Bool {
        recoveryDecisionIDs.contains(conversationID)
    }

    @discardableResult
    func restoreRecovered(conversationID: String) -> Bool {
        guard recoveryDecisionIDs.contains(conversationID) else { return false }
        do {
            try store.restoreCardDeletionWithoutWallDeadline(conversationID: conversationID, at: now())
            clearPending(conversationID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "保留会话失败，正文仍在；请重试。"
            return false
        }
    }

    @discardableResult
    func confirmRecovered(conversationID: String) -> Bool {
        guard recoveryDecisionIDs.contains(conversationID) else { return false }
        do {
            try store.confirmRecoveredCardDeletion(conversationID: conversationID, at: now())
            clearPending(conversationID)
            onFinalized(conversationID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "确认删除失败，正文仍在；请重试。"
            return false
        }
    }

    /// A lost continuous timer makes the persisted wall deadline insufficient
    /// proof of elapsed time. Keep the body until the user resolves that intent.
    func recoverPending() {
        do {
            var cursor: PendingCardDeletion?
            while true {
                let page = try store.pendingCardDeletionPage(after: cursor)
                for item in page {
                    addPending(item)
                    // A surviving timer remains the authority across foreground
                    // transitions. Rehydrating from disk cannot recreate its proof.
                    if expiryTasks[item.conversationID] == nil {
                        recoveryDecisionIDs.insert(item.conversationID)
                    }
                }
                guard page.count == 50, let last = page.last else { break }
                cursor = last
            }
            needsRecoveryRetry = false
            errorMessage = nil
        } catch {
            needsRecoveryRetry = true
            errorMessage = "待删除会话读取失败，正文已保留；请重试。"
        }
    }

    func retryFinalization(conversationID: String) {
        guard !recoveryDecisionIDs.contains(conversationID) else {
            errorMessage = "删除期限无法确认，请选择保留会话或确认删除。"
            return
        }
        guard !awaitingMonotonicExpiryIDs.contains(conversationID) else {
            errorMessage = "正在确认删除期限，请稍后重试。"
            return
        }
        expire(conversationID: conversationID)
    }

    func clearError() { errorMessage = nil }

    private func addPending(_ item: PendingCardDeletion) {
        pendingCards.removeAll { $0.conversationID == item.conversationID }
        pendingCards.append(item)
        pendingCards.sort {
            $0.deadline == $1.deadline ? $0.conversationID < $1.conversationID
                : $0.deadline < $1.deadline
        }
    }

    private func clearPending(_ conversationID: String) {
        expiryTasks.removeValue(forKey: conversationID)?.cancel()
        awaitingMonotonicExpiryIDs.remove(conversationID)
        recoveryDecisionIDs.remove(conversationID)
        pendingCards.removeAll { $0.conversationID == conversationID }
    }

    private func scheduleExpiry(for item: PendingCardDeletion) {
        if awaitingMonotonicExpiryIDs.contains(item.conversationID) { return }
        awaitingMonotonicExpiryIDs.insert(item.conversationID)
        expiryTasks.removeValue(forKey: item.conversationID)?.cancel()
        expiryTasks[item.conversationID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PersistenceStore.cardUndoWindow)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expiryTasks.removeValue(forKey: item.conversationID)
            self?.awaitingMonotonicExpiryIDs.remove(item.conversationID)
            self?.expire(conversationID: item.conversationID)
        }
    }

    private func expire(conversationID: String) {
        do {
            if try store.finalizeExpiredCardDeletion(conversationID: conversationID, at: now()) {
                clearPending(conversationID)
                onFinalized(conversationID)
                errorMessage = nil
            } else if let item = try store.pendingCardDeletion(id: conversationID) {
                // The continuous window elapsed but the wall deadline moved
                // backwards. Neither clock alone may now erase the body.
                addPending(item)
                recoveryDecisionIDs.insert(conversationID)
                errorMessage = nil
            } else {
                clearPending(conversationID)
                if try store.conversationLifecycle(id: conversationID) == .finalizedDeletion {
                    onFinalized(conversationID)
                }
            }
        } catch {
            // Failed cleanup is recoverable and must never imply an erased body.
            errorMessage = "删除收尾失败，正文已保留；请重试。"
        }
    }
}
