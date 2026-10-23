import Foundation
import Observation

struct ToolSettingsActionRow: Identifiable, Sendable {
    let toolID: String
    let displayName: String
    let action: ToolPolicyActionMetadata
    let policy: ToolPolicySnapshot
    let systemState: ToolSystemPermissionState
    var id: String { toolID + "::" + action.actionID }
}

struct ToolSettingsGrantRow: Identifiable, Sendable {
    let id: String
    let grant: ToolScopedGrant
    let invalidationReason: String?
}

/// Settings writes configuration facts; Runtime's existing kernel remains the
/// only owner of effective permission. Conservative contract before integration.
@MainActor @Observable
final class ToolSettingsModel {
    private(set) var actions: [ToolSettingsActionRow] = []
    private(set) var grants: [ToolSettingsGrantRow] = []
    private(set) var errorMessage: String?
    @ObservationIgnored let store: PersistenceStore
    @ObservationIgnored let registry: ToolRegistry
    @ObservationIgnored let safetyCap: ToolPolicySafetyCap
    init(store: PersistenceStore, registry: ToolRegistry, safetyCap: ToolPolicySafetyCap = .unrestricted) {
        self.store = store; self.registry = registry; self.safetyCap = safetyCap
    }
    func load() async { }
    func setPolicy(toolID: String, actionID: String, descriptorRevision: String, mode: ToolPersistentPolicy) async -> Bool { false }
    func revokeGrant(id: String) async -> Bool { false }
}
