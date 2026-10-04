import Foundation
import Observation

@MainActor
@Observable
final class SoulSettingsModel {
    var instructions = ""
    private(set) var enabled = false
    private(set) var hasSoul = false
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private var expectedVersionID: String?
    @ObservationIgnored private var active = true

    init(store: PersistenceStore) { self.store = store }

    func load() async {
        guard active, !isBusy, !isLoaded else { return }
        isBusy = true
        defer { isBusy = false }
        let store = store
        do {
            let snapshot = try await Task.detached { try store.soulEditingSnapshot() }.value
            guard active, !Task.isCancelled else { return }
            expectedVersionID = snapshot.version?.id
            instructions = snapshot.version?.instructions ?? ""
            enabled = snapshot.soul?.enabled ?? false
            hasSoul = snapshot.soul != nil
            isLoaded = true
            errorMessage = nil
        } catch { if active { errorMessage = "Soul 读取失败，请重试。" } }
    }

    func save() async {
        guard active, isLoaded, !isBusy else { return }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        let store = store, expected = expectedVersionID
        let version = SoulVersionRecord(id: UUID().uuidString, instructions: instructions, createdAt: Date())
        do {
            try await Task.detached {
                if let expected { try store.advanceSoul(expectedCurrentVersionID: expected, to: version, at: version.createdAt) }
                else { try store.createSoul(initialVersion: version, at: version.createdAt) }
            }.value
            guard active else { return }
            expectedVersionID = version.id
            if !hasSoul { enabled = true }
            hasSoul = true
            statusMessage = "已保存。已有会话保留原绑定版本。"
        } catch {
            if active { errorMessage = "Soul 保存失败或版本已变化。本页文字已保留，请检查后重试。" }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard active, isLoaded, hasSoul, !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        let store = store
        do {
            try await Task.detached { try store.setSoulEnabled(value, at: Date()) }.value
            if active { enabled = value }
        } catch { if active { errorMessage = "Soul 启用状态未保存，请重试。" } }
    }

    func invalidate() { active = false }
}
