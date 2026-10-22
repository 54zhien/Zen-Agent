import Foundation

extension PersistenceStore {
    func issueToolGrant(id: String, grant: ToolScopedGrant, expectedPolicy: ToolPolicySnapshot) throws -> Bool { false }
    func toolGrant(id: String) throws -> ToolScopedGrant? { nil }
    func toolGrants(subject: ToolGrantSubject) throws -> [ToolScopedGrant] { [] }
    @discardableResult func revokeToolGrant(id: String) throws -> Bool { false }
}
