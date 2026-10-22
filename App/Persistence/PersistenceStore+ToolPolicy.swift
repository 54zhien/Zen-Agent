import Foundation

extension PersistenceStore {
    func toolPolicy(toolID: String, actionID: String, descriptorRevision: String) throws -> ToolPolicySnapshot {
        ToolPolicySnapshot(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision,
            mode: .askEveryTime, revocationEpoch: 0)
    }

    @discardableResult
    func setToolPolicy(toolID: String, actionID: String, descriptorRevision: String,
                       mode: ToolPersistentPolicy) throws -> ToolPolicySnapshot {
        try toolPolicy(toolID: toolID, actionID: actionID, descriptorRevision: descriptorRevision)
    }
}
