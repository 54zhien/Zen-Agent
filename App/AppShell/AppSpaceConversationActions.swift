import Foundation
import Observation

@MainActor
@Observable
final class AppSpaceConversationActions {
    private(set) var errorMessage: String?
    private var errorTargetID: String?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private var pending: (originID: String, id: String, at: Date, binding: ConversationInitialBinding)?
    init(store: PersistenceStore) { self.store = store }
    func create(originID: String, at now: Date, initialBinding: ConversationInitialBinding = .init()) throws -> String {
        if pending?.originID != originID {
            pending = (originID, UUID().uuidString, now, initialBinding)
        }
        guard let pending else { throw PersistenceError.invalidTransition("Missing creation intent") }
        do {
            if let lifecycle = try store.conversationLifecycle(id: pending.id) {
                guard lifecycle == .visible else { throw PersistenceError.invalidTransition("Created conversation is no longer visible") }
            } else {
                try store.createEmptyConversation(id: pending.id, at: pending.at, initialBinding: pending.binding)
            }
            errorMessage = nil
            errorTargetID = nil
            return pending.id
        } catch {
            errorMessage = "新会话创建失败，原卡片已保留。请重试。"
            errorTargetID = nil
            throw error
        }
    }
    func acknowledgeCreated(id: String) { if pending?.id == id { pending = nil } }
    func reset() { pending = nil; errorMessage = nil; errorTargetID = nil }
    func error(for id: String?) -> String? { id == errorTargetID ? errorMessage : nil }
    func title(id: String) -> String? {
        do {
            guard let row = try store.conversation(id: id), row.lifecycle == .visible else { return nil }
            return row.title
        } catch { errorMessage = "会话标题读取失败，请重试。"; errorTargetID = id; return nil }
    }
    func rename(id: String, title: String) -> Bool {
        perform(id: id, message: "重命名失败，请输入有效标题并重试。") { try store.renameConversation(id: id, title: title, at: Date()) }
    }
    func pin(id: String, pinned: Bool) -> Bool {
        perform(id: id, message: "置顶状态保存失败，请重试。") { try store.setConversationPinned(id: id, pinned: pinned, at: Date()) }
    }
    private func perform(id: String, message: String, action: () throws -> Void) -> Bool {
        do { try action(); errorMessage = nil; errorTargetID = nil; return true }
        catch { errorMessage = message; errorTargetID = id; return false }
    }
}
