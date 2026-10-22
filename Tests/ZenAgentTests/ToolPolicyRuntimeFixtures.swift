import Foundation

@testable import ZenAgent

extension Fixtures {
    /// Old execution tests opt into automatic execution explicitly. Required or
    /// high-risk fixtures still need their original user approval.
    static func allowAutomaticToolPolicies(in store: PersistenceStore, registry: ToolRegistry) throws {
        for descriptor in registry.descriptors where descriptor.approvalRequirement == .notRequired {
            for action in descriptor.actions where action.risk == .low && action.allowsAutomaticApproval {
                _ = try store.setToolPolicy(toolID: action.toolID, actionID: action.actionID,
                    descriptorRevision: action.descriptorRevision, mode: .alwaysAllow)
            }
        }
    }

    static func automaticallyAllowedRegistry(in store: PersistenceStore,
        tools: [any ToolExecutable]) throws -> ToolRegistry {
        let registry = try ToolRegistry(tools: tools)
        try allowAutomaticToolPolicies(in: store, registry: registry)
        return registry
    }
}
