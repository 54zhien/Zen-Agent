import Foundation
import Observation

struct ToolSettingsActionRow: Identifiable, Sendable {
    let toolID: String
    let displayName: String
    let action: ToolPolicyActionMetadata
    let policy: ToolPolicySnapshot
    let systemState: ToolSystemPermissionState?
    var id: String { Data(toolID.utf8).base64EncodedString() + ":" + Data(action.actionID.utf8).base64EncodedString() }
}

struct ToolSettingsGrantRow: Identifiable, Sendable {
    let id: String
    let grant: ToolScopedGrant
    let invalidationReason: String?
}

/// Settings writes configuration facts; Runtime's existing kernel remains the
/// only owner of effective permission.
@MainActor @Observable
final class ToolSettingsModel {
    private(set) var actions: [ToolSettingsActionRow] = []
    private(set) var grants: [ToolSettingsGrantRow] = []
    private(set) var errorMessage: String?
    private(set) var isWorking = false
    @ObservationIgnored let store: PersistenceStore
    @ObservationIgnored let registry: ToolRegistry
    @ObservationIgnored let safetyCap: ToolPolicySafetyCap
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var active = true
    init(store: PersistenceStore, registry: ToolRegistry, safetyCap: ToolPolicySafetyCap = .unrestricted) {
        self.store = store; self.registry = registry; self.safetyCap = safetyCap
    }
    func load() async {
        guard active else { return }
        generation &+= 1
        let captured = generation
        let store = store, registry = registry
        do {
            let facts = try await Task.detached {
                try registry.descriptors.flatMap { descriptor -> [ToolSettingsActionRow] in
                    guard let current = registry.executor(id: descriptor.id)?.descriptor,
                          ToolPolicyIdentity.equals(current.revision, descriptor.revision),
                          current.actions == descriptor.actions else { return [] }
                    return try descriptor.actions.filter { action in
                        action.isKnown && descriptor.actions.filter {
                            ToolPolicyIdentity.equals($0.actionID, action.actionID)
                        }.count == 1
                    }.map { action in
                        ToolSettingsActionRow(toolID: descriptor.id, displayName: descriptor.displayName,
                            action: action, policy: try store.toolPolicy(toolID: descriptor.id,
                                actionID: action.actionID, descriptorRevision: descriptor.revision), systemState: nil)
                    }
                }
            }.value
            var rows: [ToolSettingsActionRow] = []
            for fact in facts {
                let state: ToolSystemPermissionState?
                if let owner = registry.executor(id: fact.toolID) as? any ToolSystemPermissionProviding {
                    do { state = try await owner.systemPermissionStateForSettings() }
                    catch { state = .unavailable }
                } else { state = .notRequired }
                rows.append(ToolSettingsActionRow(toolID: fact.toolID, displayName: fact.displayName,
                    action: fact.action, policy: fact.policy, systemState: state))
            }
            let grants = try await Task.detached { try store.toolGrantsForSettings() }.value
            guard active, generation == captured, !Task.isCancelled else { return }
            actions = rows
            self.grants = grants.map {
                ToolSettingsGrantRow(id: $0.id, grant: $0.grant,
                    invalidationReason: Self.invalidationText($0.invalidation, validity: $0.grant.validity)
                        ?? currentDescriptorNotice(for: $0.grant))
            }
            errorMessage = nil
        } catch {
            if active, generation == captured {
                actions = []; grants = []
                errorMessage = "工具与授权记录读取失败，请重试。"
            }
        }
    }

    func setPolicy(toolID: String, actionID: String, descriptorRevision: String, mode: ToolPersistentPolicy) async -> Bool {
        guard active, !isWorking, let executor = registry.executor(id: toolID),
              ToolPolicyIdentity.equals(executor.descriptor.revision, descriptorRevision),
              executor.descriptor.actions.filter({
                  ToolPolicyIdentity.equals($0.actionID, actionID) && $0.isKnown
              }).count == 1 else { return false }
        isWorking = true; generation &+= 1
        defer { isWorking = false }
        let store = store
        do {
            _ = try await Task.detached {
                try store.setToolPolicy(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision, mode: mode)
            }.value
            await load()
            return true
        } catch {
            if active { errorMessage = "工具策略保存失败，请重试。" }
            return false
        }
    }

    func revokeGrant(id: String) async -> Bool {
        guard active, !isWorking else { return false }
        isWorking = true; generation &+= 1
        defer { isWorking = false }
        let store = store
        do {
            let changed = try await Task.detached { try store.revokeToolGrant(id: id) }.value
            await load()
            return changed
        } catch {
            if active { errorMessage = "授权撤销失败，请重试。" }
            return false
        }
    }

    func invalidate() { active = false; generation &+= 1 }

    private func currentDescriptorNotice(for grant: ToolScopedGrant) -> String? {
        guard grant.validity == .active else { return nil }
        guard let descriptor = registry.executor(id: grant.toolID)?.descriptor else {
            return "工具当前不可用；授权记录仍可撤销。"
        }
        // This explains a declared identity mismatch, without recomputing
        // effective permission or altering the original issuance.
        guard ToolPolicyIdentity.equals(descriptor.revision, grant.descriptorRevision),
              descriptor.actions.contains(where: { ToolPolicyIdentity.equals($0.actionID, grant.actionID) }) else {
            return "动作版本或可用动作已变化，需要重新确认。"
        }
        return nil
    }

    private static func invalidationText(_ reason: ToolGrantInvalidationReason?, validity: ToolGrantValidity) -> String? {
        if validity == .consumed { return "本次授权已消费或原调用已结束。" }
        guard validity == .revoked else { return nil }
        switch reason {
        case .policyTightened: return "长期策略已收紧或动作版本已变化。"
        case .subjectEnded: return "授权主体已结束或会话已删除。"
        case .manualRevocation: return "用户已撤销此授权。"
        case .legacyUnspecified, nil: return "历史撤销记录，原因未记录。"
        }
    }
}
