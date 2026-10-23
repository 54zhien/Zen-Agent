import Foundation

/// Validation/redaction can inspect known material; workflow and executor inputs
/// never receive this inventory. Missing protected data fails closed.
enum SecretContentGuard {
    static func knownSecrets(store: PersistenceStore, credentials: (any CredentialStoring)?) throws -> [SecretValue] {
        let references = Set(try store.providerInstances().compactMap(\.credentialReference)
            + store.environmentCredentialBindings().map { $0.reference })
        guard let credentials else {
            guard references.isEmpty else { throw EnvironmentError.validationUnavailable }
            return []
        }
        var result: [SecretValue] = []
        for reference in references {
            guard let metadata = try credentials.metadata(for: reference) else { throw EnvironmentError.validationUnavailable }
            if metadata.status == .active {
                guard let secret = try credentials.resolve(reference) else { throw EnvironmentError.validationUnavailable }
                result.append(secret)
            }
        }
        return result
    }

    static func allows(_ value: String, store: PersistenceStore, credentials: any CredentialStoring) throws -> Bool {
        let secrets = try knownSecrets(store: store, credentials: credentials)
        let result = ToolResultGuard.sanitize(ToolExecutionResult(content: value), knownSecrets: secrets)
        return result.failure == nil && result.content.utf8.elementsEqual(value.utf8)
    }
}
