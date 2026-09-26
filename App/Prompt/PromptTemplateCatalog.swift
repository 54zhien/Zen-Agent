import Foundation

struct PromptSystemSections: Sendable, Equatable {
    let runtimeSafety: String
    let zenCore: String
}

/// Built-in prompt text is kept by immutable revision so a prepared Run never
/// silently switches to a newer Core or Safety template after an app update.
enum PromptTemplateCatalog {
    enum ResolutionError: Error, Equatable, Sendable {
        case unsupportedRuntimeSafety(String)
        case unsupportedZenCore(String)
    }

    static let currentRuntimeSafetyRevision = "runtime-safety-v1"
    static let currentZenCoreRevision = "zen-core-v1"

    static let current = PromptSystemSections(
        runtimeSafety: """
        Do not claim that an external action or result occurred unless it is present in the provided context.
        If a tool or external action fails, report the failure as it happened.
        """,
        zenCore: """
        Answer the user's current request directly and clearly.
        Do not mechanically repeat background context.
        State uncertainty when needed.
        """
    )

    static func resolve(
        runtimeSafetyRevision: String,
        zenCoreRevision: String
    ) throws -> PromptSystemSections {
        guard runtimeSafetyRevision == currentRuntimeSafetyRevision else {
            throw ResolutionError.unsupportedRuntimeSafety(runtimeSafetyRevision)
        }
        guard zenCoreRevision == currentZenCoreRevision else {
            throw ResolutionError.unsupportedZenCore(zenCoreRevision)
        }
        return current
    }
}
