import Foundation

/// A content-free identity for the declared configuration used by one workflow.
struct EnvironmentBindingSnapshot: Codable, Sendable, Equatable {
    let references: [EnvironmentRevisionReference]
    let fingerprint: String
}

extension EnvironmentRuntime {
    func bind(skillID: String, declaredKeys: [String]) throws -> EnvironmentBindingSnapshot {
        throw EnvironmentError.missingReference
    }

    func interpolate(_ text: String, binding: EnvironmentBindingSnapshot, skillID: String,
                     declaredKeys: [String]) throws -> String {
        throw EnvironmentError.missingReference
    }

    /// Trusted executor seam. It is never registered as a model-callable Tool.
    func resolveSecret(key: String, binding: EnvironmentBindingSnapshot, skillID: String,
                       declaredKeys: [String]) throws -> SecretValue {
        throw EnvironmentError.missingReference
    }
}
