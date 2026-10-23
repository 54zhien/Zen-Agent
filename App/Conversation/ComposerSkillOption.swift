import Foundation

/// A menu projection only. Send revalidates the definition and its dependencies.
struct ComposerSkillOption: Sendable, Equatable {
    let id: String
    let name: String
    let isAvailable: Bool
}
