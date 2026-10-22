import Foundation
import Testing

@testable import ZenAgent

extension Fixtures {
    /// A parked approval is not completion. Bound test waiting, report the actual
    /// durable checkpoint, then drain the real Runtime so a regression cannot
    /// silently consume the whole CI deadline.
    static func awaitTerminalRun(in store: PersistenceStore, runtime: ConversationRuntime,
                                 runID: String) async throws {
        for _ in 0..<1000 {
            if try store.run(id: runID)?.state.isTerminal == true {
                try await runtime.waitForCompletion(runID: runID)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try store.run(id: runID)?.state.rawValue ?? "missing"
        Issue.record("Runtime did not finish; durable checkpoint: \(state)")
        if try store.run(id: runID)?.state.isActive == true { try await runtime.stop(runID: runID) }
        try await runtime.waitForCompletion(runID: runID)
    }

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
