import Foundation
import Testing

@testable import ZenAgent

extension Fixtures {
    /// Bound the real owner task, not its database state: an injected failure
    /// to write a terminal state deliberately leaves an active durable row while
    /// completing with the original error.
    static func awaitRuntimeCompletion(in store: PersistenceStore, runtime: ConversationRuntime,
                                       runID: String) async throws {
        let observed = RuntimeTestCompletionFlag()
        let completion = Task {
            do {
                try await runtime.waitForCompletion(runID: runID)
                await observed.finish()
            } catch {
                await observed.finish()
                throw error
            }
        }
        defer { completion.cancel() }
        for _ in 0..<1000 {
            if await observed.isFinished() {
                try await completion.value
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try store.run(id: runID)?.state.rawValue ?? "missing"
        Issue.record("Runtime task did not finish; durable checkpoint: \(state)")
        if try store.run(id: runID)?.state.isActive == true { try await runtime.stop(runID: runID) }
        try await completion.value
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

private actor RuntimeTestCompletionFlag {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}
