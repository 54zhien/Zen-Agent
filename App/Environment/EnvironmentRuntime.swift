import Foundation

/// Trusted configuration owner. Workflow text receives prepared non-secret data only.
struct EnvironmentRuntime: Sendable {
    let store: PersistenceStore
    let credentials: any CredentialStoring

    func list() throws -> [EnvironmentItem] { [] }

    @discardableResult
    func savePlain(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                   key: String, value: String) throws -> EnvironmentItem {
        throw EnvironmentError.validationUnavailable
    }

    @discardableResult
    func saveSecret(id: String? = nil, expectedRevisionID: String? = nil, scope: EnvironmentScope = .global,
                    key: String, value: SecretValue) throws -> EnvironmentItem {
        throw EnvironmentError.validationUnavailable
    }

    func resolveFrozen(_ references: [EnvironmentRevisionReference]) throws -> [EnvironmentItem] {
        throw EnvironmentError.erasedDependency
    }

    func delete(id: String) async throws { throw EnvironmentError.validationUnavailable }
}
