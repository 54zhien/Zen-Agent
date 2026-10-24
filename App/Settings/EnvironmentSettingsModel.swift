import Foundation
import Observation

@MainActor
@Observable
final class EnvironmentSettingsModel {
    private(set) var items: [EnvironmentItem] = []
    private(set) var skills: [SkillItem] = []
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var skillListErrorMessage: String?
    private(set) var cleanupStatusMessage: String?
    private(set) var pendingCleanupCount: Int?

    @ObservationIgnored private let runtime: EnvironmentRuntime
    @ObservationIgnored private let skillRuntime: SkillRuntime
    @ObservationIgnored private var active = true

    init(runtime: EnvironmentRuntime, skills: SkillRuntime) {
        self.runtime = runtime
        self.skillRuntime = skills
    }

    func item(id: String) -> EnvironmentItem? {
        items.first { $0.id == id }
    }

    func skillName(id: String) -> String? {
        skills.first { $0.id == id }?.definition.name
    }

    func load() async {
        guard active, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await reload(retryCleanup: true)
    }

    func retryCredentialCleanup() async {
        guard active, !isBusy else { return }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        await reload(retryCleanup: true)
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
            errorMessage = "变量影响范围暂时无法读取，请重试。"
            return nil
        }
    }

    @discardableResult
    func savePlain(id: String? = nil, expectedRevisionID: String? = nil,
                   scope: EnvironmentScope = .global, key: String, value: String) async -> EnvironmentItem? {
        guard active, !isBusy else { return nil }
        if let id, item(id: id)?.pendingDeletion == true {
            errorMessage = "此变量正在等待删除，暂时不能编辑。"
            return nil
        }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let runtime = runtime
            let saved = try await Task.detached {
                try runtime.savePlain(id: id, expectedRevisionID: expectedRevisionID, scope: scope,
                                      key: key, value: value)
            }.value
            guard active else { return nil }
            errorMessage = nil
            await reload(retryCleanup: false)
            statusMessage = "已保存。之后的新 Run 会使用更新后的配置。"
            return saved
        } catch {
            guard active else { return nil }
            errorMessage = safeMessage(for: error, operation: .save)
            await reload(retryCleanup: false, preservingError: true)
            return nil
        }
    }

    @discardableResult
    func saveSecret(id: String? = nil, expectedRevisionID: String? = nil,
                    scope: EnvironmentScope = .global, key: String, value: SecretValue?) async -> EnvironmentItem? {
        guard active, !isBusy else { return nil }
        if let id, item(id: id)?.pendingDeletion == true {
            errorMessage = "此变量正在等待删除，暂时不能编辑。"
            return nil
        }
        guard let value else {
            guard let id else {
                errorMessage = "请输入要保存的密钥。"
                return nil
            }
            isBusy = true
            statusMessage = nil
            defer { isBusy = false }
            do {
                let runtime = runtime
                let existing = try await Task.detached {
                    try runtime.list().first { $0.id == id }
                }.value
                guard active else { return nil }
                guard let existing, case .secret = existing.value else {
                    errorMessage = "请输入要保存的密钥。"
                    return nil
                }
                guard existing.revisionID == expectedRevisionID else {
                    errorMessage = "变量已被其他操作更新；请刷新后确认是否保留现有密钥。"
                    return nil
                }
                guard !existing.pendingDeletion else {
                    errorMessage = "此变量正在等待删除，暂时不能编辑。"
                    return nil
                }
                errorMessage = nil
                statusMessage = "密钥未更改，现有密钥仍保持保存状态。"
                return existing
            } catch {
                guard active else { return nil }
                errorMessage = safeMessage(for: error, operation: .save)
                return nil
            }
        }
        guard !value.revealed.isEmpty else {
            errorMessage = "请输入要保存的密钥。"
            return nil
        }
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let runtime = runtime
            let saved = try await Task.detached {
                try await runtime.saveSecret(id: id, expectedRevisionID: expectedRevisionID, scope: scope,
                                       key: key, value: value)
            }.value
            guard active else { return nil }
            errorMessage = nil
            await reload(retryCleanup: false)
            statusMessage = "密钥已保存。它仅供可信执行边界使用，不会发送到模型。"
            return saved
        } catch {
            guard active else { return nil }
            errorMessage = safeMessage(for: error, operation: .save)
            await reload(retryCleanup: false, preservingError: true)
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
            errorMessage = nil
            await reload(retryCleanup: false)
            statusMessage = "变量已删除。"
            return !items.contains { $0.id == id }
        } catch {
            guard active else { return false }
            errorMessage = safeMessage(for: error, operation: .delete)
            await reload(retryCleanup: false, preservingError: true)
            return !items.contains { $0.id == id }
        }
    }

    private func reload(retryCleanup: Bool, preservingError: Bool = false) async {
        guard active else { return }
        let runtime = runtime
        let skillRuntime = skillRuntime
        let snapshot = await Task.detached { () -> EnvironmentSettingsSnapshot in
            var cleanupFailed = false
            if retryCleanup {
                do { try runtime.retryCredentialCleanup() }
                catch { cleanupFailed = true }
            }
            return EnvironmentSettingsSnapshot(
                items: try? runtime.list(),
                skills: try? skillRuntime.list(),
                pendingCleanupCount: try? runtime.pendingCleanupCount(),
                cleanupFailed: cleanupFailed
            )
        }.value
        guard active, !Task.isCancelled else { return }
        if let items = snapshot.items {
            self.items = items
            isLoaded = true
            if !preservingError { errorMessage = nil }
        } else {
            isLoaded = false
            if !preservingError { errorMessage = "环境变量读取失败，请重试。" }
        }
        if let skills = snapshot.skills {
            self.skills = skills
            skillListErrorMessage = nil
        } else {
            skillListErrorMessage = "技能列表暂不可用，当前无法创建技能范围变量。"
        }
        pendingCleanupCount = snapshot.pendingCleanupCount
        if snapshot.cleanupFailed {
            if let count = snapshot.pendingCleanupCount, count > 0 {
                cleanupStatusMessage = "有 " + String(count) + " 项密钥清理待重试。"
            } else {
                cleanupStatusMessage = "密钥清理暂时无法确认，请重试。"
            }
        } else if let count = snapshot.pendingCleanupCount, count > 0 {
            cleanupStatusMessage = "有 " + String(count) + " 项密钥清理待重试。"
        } else if snapshot.pendingCleanupCount == nil {
            cleanupStatusMessage = "密钥清理状态暂时无法读取，请重试。"
        } else {
            cleanupStatusMessage = nil
        }
    }

    func invalidate() {
        active = false
    }

    private enum Operation { case save, delete }

    private func safeMessage(for error: Error, operation: Operation) -> String {
        switch error as? EnvironmentError {
        case .invalidKey: return "变量名称无效，请使用字母、数字和下划线。"
        case .invalidValue: return "变量值为空、过长或格式不受支持。"
        case .duplicateKey: return "此作用范围内已存在同名变量。"
        case .editConflict: return "变量已被其他操作更新；你的编辑仍保留，请刷新后再保存。"
        case .notFound, .erasedDependency: return "变量已不可用，请刷新列表后重试。"
        case .invalidScope: return "所选技能已不可用，请重新选择作用范围。"
        case .validationUnavailable: return "变量暂时无法保存，请稍后重试。"
        case .unsafeContent: return "纯文本值不能包含已保存的密钥或其他敏感凭据。"
        case .missingReference: return "变量依赖已失效，请刷新后检查技能配置。"
        case .cycle: return "变量引用形成循环，无法保存。"
        case .secretInterpolation: return "密钥不能插入技能指令或普通输出。"
        case .resourceInUse: return "依赖运行尚未停止，删除请求已保留为待处理状态。"
        case .cleanupPending: return "密钥清理仍待重试；请刷新后查看变量状态。"
        case nil:
            switch operation {
            case .save: return "变量未保存，编辑内容仍保留，请重试。"
            case .delete: return "变量删除尚未完成，请刷新后重试。"
            }
        }
    }
}

private struct EnvironmentSettingsSnapshot: Sendable {
    let items: [EnvironmentItem]?
    let skills: [SkillItem]?
    let pendingCleanupCount: Int?
    let cleanupFailed: Bool
}
