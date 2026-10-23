import Foundation
import Observation

@MainActor
@Observable
final class MemorySettingsModel {
    private(set) var items: [MemoryItem] = []
    private(set) var settings = MemorySettings(enabled: true, automaticEnabled: false, generation: 0)
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let runtime: MemoryRuntime
    @ObservationIgnored private var active = true

    init(runtime: MemoryRuntime) { self.runtime = runtime }

    func load() async {
        guard active, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        let store = runtime.store
        do {
            let snapshot = try await Task.detached { (try store.memorySettings(), try store.memories()) }.value
            guard active, !Task.isCancelled else { return }
            settings = snapshot.0; items = snapshot.1; isLoaded = true; errorMessage = nil
        } catch { if active { errorMessage = "记忆读取失败，请重试。" } }
    }

    func setEnabled(_ enabled: Bool) async {
        await change { try $0.setEnabled(enabled) }
    }
    func setAutomatic(_ enabled: Bool) async {
        await change { try $0.setAutomatic(enabled) }
    }

    private func change(_ body: @escaping @Sendable (MemoryRuntime) throws -> Void) async {
        guard active, isLoaded, !isBusy else { return }
        isBusy = true
        let runtime = runtime
        do {
            try await Task.detached { try body(runtime) }.value
            if active { settings = try runtime.store.memorySettings(); errorMessage = nil }
        } catch { if active { errorMessage = "记忆设置未保存，请重试。" } }
        isBusy = false
    }

    func save(_ item: MemoryItem, content: String) async -> MemoryItem? {
        guard active, !isBusy else { return nil }
        isBusy = true; defer { isBusy = false }
        let runtime = runtime
        do {
            let updated = try await Task.detached {
                try runtime.save(id: item.id, expectedRevisionID: item.revisionID, content: content)
            }.value
            guard active else { return nil }
            items = try runtime.store.memories(); errorMessage = nil
            return updated
        } catch {
            if active {
                switch error as? MemoryError {
                case .unsafeContent: errorMessage = "这段内容无法作为长期记忆保存。请移除密钥、敏感凭据、指令或不确定的陈述。"
                case .editConflict: errorMessage = "记忆已被其他操作更新。编辑文字已保留，请返回列表刷新后再编辑。"
                default: errorMessage = "记忆未保存，编辑文字已保留，请重试。"
                }
            }
            return nil
        }
    }

    func delete(_ item: MemoryItem) async -> Bool {
        guard active, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            try await runtime.delete(id: item.id)
            if active { items = try runtime.store.memories(); errorMessage = nil }
            return true
        } catch { if active { errorMessage = "记忆未删除，请重试。" }; return false }
    }

    func clear() async {
        guard active, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await runtime.clear()
            if active { items = []; settings = try runtime.store.memorySettings(); errorMessage = nil }
        } catch { if active { errorMessage = "记忆未清空，请重试。" } }
    }
    func invalidate() { active = false }
}
