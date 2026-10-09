import Foundation
import Observation

struct SettingsStorageFootprint: Sendable {
    let databaseBytes: Int64?
    let managedBytes: Int64
    let cacheBytes: Int64
    let conversations: Int
    let messages: Int
    let fileAssets: Int
    let snapshots: Int
}

@MainActor
@Observable
final class SettingsStorageModel {
    private(set) var footprint: SettingsStorageFootprint?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let files: ManagedFileStore
    @ObservationIgnored private var active = true

    init(store: PersistenceStore, files: ManagedFileStore) { self.store = store; self.files = files }
    func refresh() async { await measure(clearing: false) }
    func clearCache() async { await measure(clearing: true) }
    func invalidate() { active = false }

    private func measure(clearing: Bool) async {
        guard active, !isBusy else { return }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        let store = store, files = files
        do {
            let result = try await Task.detached {
                let removed = clearing ? try files.clearPresentationCache() : 0
                let database = try store.settingsDatabaseFootprint()
                let footprint = SettingsStorageFootprint(databaseBytes: database.bytes,
                    managedBytes: try files.managedByteCount(), cacheBytes: try files.presentationCacheByteCount(),
                    conversations: database.conversations, messages: database.messages,
                    fileAssets: database.fileAssets, snapshots: database.snapshots)
                return (footprint, removed)
            }.value
            guard active, !Task.isCancelled else { return }
            footprint = result.0
            if clearing { statusMessage = "已清理 \(result.1) 份临时副本。正在预览或导出的副本继续保留。" }
        } catch {
            if active { errorMessage = clearing ? "缓存清理或用量读取未完成，请刷新后检查。" : "存储用量读取失败，请重试。" }
        }
    }
}
