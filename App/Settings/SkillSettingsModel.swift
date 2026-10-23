import Foundation
import Observation

@MainActor
@Observable
final class SkillSettingsModel {
    private(set) var items: [SkillItem] = []
    private(set) var dependencyStatuses: [String: SkillDependencyStatus] = [:]
    private(set) var dependencyReadFailures: Set<String> = []
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?

    @ObservationIgnored private let runtime: SkillRuntime
    @ObservationIgnored private var active = true

    init(runtime: SkillRuntime) {
        self.runtime = runtime
    }

    func item(id: String) -> SkillItem? {
        items.first { $0.id == id }
    }

    func load() async {
        guard active, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await reload()
    }

    func setEnabled(id: String, enabled: Bool) async {
        guard active, !isBusy else { return }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            try await runtime.setEnabled(id: id, enabled: enabled)
            guard active else { return }
            await reload()
            if errorMessage == nil { statusMessage = enabled ? "技能已启用。" : "技能已停用。" }
        } catch {
            guard active else { return }
            errorMessage = safeMessage(for: error, operation: .update)
            await reload(preservingError: true)
        }
    }

    func copyDefinition(id: String) async -> SkillDefinition? {
        guard active, !isBusy else { return nil }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let runtime = runtime
            let definition = try await Task.detached { try runtime.copyDefinition(id: id) }.value
            guard active else { return nil }
            errorMessage = nil
            return definition
        } catch {
            guard active else { return nil }
            errorMessage = safeMessage(for: error, operation: .copy)
            return nil
        }
    }

    @discardableResult
    func saveUser(id: String? = nil, expectedRevisionID: String? = nil,
                  definition: SkillDefinition) async -> SkillItem? {
        guard active, !isBusy else { return nil }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let runtime = runtime
            let saved = try await Task.detached {
                try runtime.saveUser(id: id, expectedRevisionID: expectedRevisionID, definition: definition)
            }.value
            guard active else { return nil }
            await reload()
            if errorMessage == nil { statusMessage = "已保存。之后的新 Run 会使用此版本。" }
            return saved
        } catch {
            guard active else { return nil }
            errorMessage = safeMessage(for: error, operation: .save)
            await reload(preservingError: true)
            return nil
        }
    }

    func dependencies(id: String) async -> ExtensionDependencySummary? {
        guard active, !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let runtime = runtime
            let summary = try await Task.detached { try runtime.dependencies(id: id) }.value
            guard active else { return nil }
            errorMessage = nil
            return summary
        } catch {
            guard active else { return nil }
            errorMessage = "技能影响范围暂时无法读取，请重试。"
            return nil
        }
    }

    func delete(id: String) async -> Bool {
        guard active, !isBusy else { return false }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            try await runtime.delete(id: id)
            guard active else { return false }
            await reload()
            if errorMessage == nil { statusMessage = "技能已删除。" }
            return !items.contains { $0.id == id }
        } catch {
            guard active else { return false }
            errorMessage = safeMessage(for: error, operation: .delete)
            await reload(preservingError: true)
            return !items.contains { $0.id == id }
        }
    }

    private func reload(preservingError: Bool = false) async {
        guard active else { return }
        let runtime = runtime
        do {
            let snapshot = try await Task.detached { () -> SkillSettingsSnapshot in
                let items = try runtime.list()
                var statuses: [String: SkillDependencyStatus] = [:]
                var failures = Set<String>()
                for item in items {
                    do { statuses[item.id] = try runtime.dependencyStatus(for: item) }
                    catch { failures.insert(item.id) }
                }
                return SkillSettingsSnapshot(items: items, statuses: statuses, failures: failures)
            }.value
            guard active, !Task.isCancelled else { return }
            items = snapshot.items
            dependencyStatuses = snapshot.statuses
            dependencyReadFailures = snapshot.failures
            isLoaded = true
            if !preservingError {
                errorMessage = snapshot.failures.isEmpty ? nil : "部分技能的依赖状态暂时无法读取。"
            }
        } catch {
            guard active else { return }
            isLoaded = false
            if !preservingError { errorMessage = "技能列表读取失败，请重试。" }
        }
    }

    func invalidate() {
        active = false
    }

    private enum Operation { case copy, save, update, delete }

    private func safeMessage(for error: Error, operation: Operation) -> String {
        switch error as? SkillError {
        case .invalidDefinition: return "技能内容不符合要求，请检查名称、指令和依赖字段。"
        case .notFound, .erasedDependency: return "技能已不可用，请刷新列表后重试。"
        case .editConflict: return "技能已被其他操作更新；你的编辑仍保留，请刷新后再保存。"
        case .builtInReadOnly: return "内置技能不能直接修改，请复制后编辑。"
        case .disabled: return "技能当前已停用，请先启用后重试。"
        case .missingDependency: return "技能仍有缺失依赖，请检查依赖配置。"
        case .unsafeContent: return "这段指令包含不允许保存的内容，请移除敏感凭据或不安全指令。"
        case .resourceInUse: return "技能正在被运行使用，删除请求已保留为待处理状态。"
        case .validationUnavailable: return "技能暂时无法保存，请稍后重试。"
        case nil:
            switch operation {
            case .copy: return "技能副本暂时无法读取，请重试。"
            case .save: return "技能未保存，编辑内容仍保留，请重试。"
            case .update: return "技能状态未更新，请重试。"
            case .delete: return "技能删除尚未完成，请刷新后重试。"
            }
        }
    }
}

private struct SkillSettingsSnapshot: Sendable {
    let items: [SkillItem]
    let statuses: [String: SkillDependencyStatus]
    let failures: Set<String>
}
