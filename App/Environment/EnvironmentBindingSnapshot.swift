import Foundation

/// A content-free identity for the declared configuration used by one workflow.
struct EnvironmentBindingSnapshot: Codable, Sendable, Equatable {
    let references: [EnvironmentRevisionReference]
    let fingerprint: String
}

extension EnvironmentRuntime {
    func bind(skillID: String, declaredKeys: [String]) throws -> EnvironmentBindingSnapshot {
        guard try store.environmentScopeExists(.skill(skillID)) else { throw EnvironmentError.invalidScope }
        let items = try EnvironmentResolution.select(skillID: skillID, declaredKeys: declaredKeys, available: list())
        for item in items {
            if case .plain(let value) = item.value {
                _ = try EnvironmentResolution.interpolate(value, items: items, declaredKeys: declaredKeys)
            }
        }
        _ = try resolveFrozen(items.map(\.reference))
        return .init(references: items.map(\.reference), fingerprint: EnvironmentBindingIdentity.fingerprint(
            skillID: skillID, keys: declaredKeys, references: items.map(\.reference)))
    }

    func interpolate(_ text: String, binding: EnvironmentBindingSnapshot, skillID: String,
                     declaredKeys: [String]) throws -> String {
        let items = try boundItems(binding, skillID: skillID, declaredKeys: declaredKeys)
        return try EnvironmentResolution.interpolate(text, items: items, declaredKeys: declaredKeys)
    }

    /// Trusted executor seam. It is never registered as a model-callable Tool.
    func resolveSecret(key: String, binding: EnvironmentBindingSnapshot, skillID: String,
                       declaredKeys: [String]) throws -> SecretValue {
        let items = try boundItems(binding, skillID: skillID, declaredKeys: declaredKeys)
        guard let item = items.first(where: { $0.key == key }), case .secret(let secret) = item.value else { throw EnvironmentError.missingReference }
        do {
            guard let value = try credentials.resolve(frozenReference: secret.reference, generation: secret.generation) else { throw EnvironmentError.erasedDependency }
            return value
        } catch let error as CredentialError {
            if case .unavailable = error { throw EnvironmentError.validationUnavailable }
            throw EnvironmentError.erasedDependency
        }
    }

    private func boundItems(_ binding: EnvironmentBindingSnapshot, skillID: String, declaredKeys: [String]) throws -> [EnvironmentItem] {
        guard binding.fingerprint == EnvironmentBindingIdentity.fingerprint(skillID: skillID, keys: declaredKeys, references: binding.references),
              declaredKeys.count <= 32, Set(declaredKeys).count == declaredKeys.count else { throw EnvironmentError.erasedDependency }
        let items = try resolveFrozen(binding.references)
        guard Set(items.map(\.key)) == Set(declaredKeys), Set(items.map(\.key)).count == items.count,
              items.allSatisfy({ $0.scope == .global || $0.scope == .skill(skillID) }) else { throw EnvironmentError.erasedDependency }
        return items
    }
}
