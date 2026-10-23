import Foundation

/// Definition lifecycle and workflow selection; ToolRuntime retains all authority.
struct SkillRuntime: Sendable {
    let store: PersistenceStore
    let credentials: any CredentialStoring
    let registry: ToolRegistry
    let stopRuns: EnvironmentRuntime.StopRuns?

    init(store: PersistenceStore, credentials: any CredentialStoring, registry: ToolRegistry,
         stopRuns: EnvironmentRuntime.StopRuns? = nil) {
        self.store = store; self.credentials = credentials; self.registry = registry; self.stopRuns = stopRuns
    }
    func list() throws -> [SkillItem] { [] }
    func dependencyStatus(for item: SkillItem) throws -> SkillDependencyStatus {
        .init(missing: ["功能尚未接入"])
    }
    func copyDefinition(id: String) throws -> SkillDefinition { throw SkillError.notFound }
    @discardableResult
    func saveUser(id: String? = nil, expectedRevisionID: String? = nil, definition: SkillDefinition) throws -> SkillItem {
        throw SkillError.validationUnavailable
    }
    func setEnabled(id: String, enabled: Bool) async throws { throw SkillError.validationUnavailable }
    func delete(id: String) async throws { throw SkillError.validationUnavailable }
    func prepare(query: String, selectedSkillIDs: [String]) throws -> [SkillContext] { [] }
    func resolveFrozen(_ references: [SkillActivationReference]) throws -> [SkillContext] {
        throw SkillError.erasedDependency
    }
}
