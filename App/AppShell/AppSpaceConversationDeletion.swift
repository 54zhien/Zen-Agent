import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceConversationDeletion {
    typealias RunAction = @MainActor (String) async throws -> Void

    private(set) var pendingCards: [PendingCardDeletion] = []
    var pending: PendingCardDeletion? { pendingCards.last }
    private(set) var errorMessage: String?
    private(set) var isDeleting = false

    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let stopRun: RunAction
    @ObservationIgnored private let waitForRun: RunAction
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var expiryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var recoveryGraceIDs: Set<String> = []

    init(store: PersistenceStore, stopRun: @escaping RunAction,
         waitForRun: @escaping RunAction, now: @escaping @MainActor () -> Date) {
        self.store = store
        self.stopRun = stopRun
        self.waitForRun = waitForRun
        self.now = now
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
            scheduleExpiry(for: committed, recovered: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "无法删除会话，原卡片已保留。请重试。"
            return false
        }
    }

    @discardableResult
    func undo(conversationID: String) -> Bool {
        do {
            try store.undoCardDeletion(conversationID: conversationID, at: now())
            expiryTasks.removeValue(forKey: conversationID)?.cancel()
            recoveryGraceIDs.remove(conversationID)
            pendingCards.removeAll { $0.conversationID == conversationID }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "撤销未完成，请检查会话状态或重试。"
            return false
        }
    }

    /// Rehydrate only the bounded deadline index. A fresh monotonic grace period
    /// after launch prevents a jumped wall clock from causing immediate erasure.
    /// Undo still checks the original persisted deadline; this grace never resets it.
    func recoverPending(afterLaunch: Bool = true) {
        do {
            var cursor: PendingCardDeletion?
            while true {
                let page = try store.pendingCardDeletionPage(after: cursor)
                for item in page {
                    addPending(item)
                    scheduleExpiry(for: item, recovered: afterLaunch)
                }
                guard page.count == 50, let last = page.last else { break }
                cursor = last
            }
            errorMessage = nil
        } catch {
            errorMessage = "待删除会话读取失败，正文已保留；请重试。"
        }
    }

    func retryFinalization(conversationID: String) {
        guard !recoveryGraceIDs.contains(conversationID) else {
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

    private func scheduleExpiry(for item: PendingCardDeletion, recovered: Bool) {
        if !recovered && recoveryGraceIDs.contains(item.conversationID) { return }
        if recovered { recoveryGraceIDs.insert(item.conversationID) }
        expiryTasks.removeValue(forKey: item.conversationID)?.cancel()
        let remaining = max(0, item.deadline.timeIntervalSince(now()))
        let delay = max(recovered ? Self.cardUndoRecoveryGrace : 0, remaining)
        expiryTasks[item.conversationID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.recoveryGraceIDs.remove(item.conversationID)
            self?.expire(conversationID: item.conversationID)
        }
    }

    private static let cardUndoRecoveryGrace: TimeInterval = 10

    private func expire(conversationID: String) {
        do {
            if try store.finalizeExpiredCardDeletion(conversationID: conversationID, at: now()) {
                expiryTasks.removeValue(forKey: conversationID)
                pendingCards.removeAll { $0.conversationID == conversationID }
                errorMessage = nil
            } else if let item = try store.pendingCardDeletion(id: conversationID) {
                // A backward clock adjustment retains the body. The absolute
                // deadline remains unchanged; a later monotonic wake retries.
                scheduleExpiry(for: item, recovered: false)
            } else {
                expiryTasks.removeValue(forKey: conversationID)
                pendingCards.removeAll { $0.conversationID == conversationID }
            }
        } catch {
            // Failed cleanup is recoverable and must never imply an erased body.
            errorMessage = "删除收尾失败，正文已保留；请重试。"
        }
    }
}
