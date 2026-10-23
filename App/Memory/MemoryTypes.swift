import Foundation

enum MemoryError: Error, Equatable, Sendable {
    case unsafeContent, validationUnavailable, editConflict, notFound, erasedDependency
}

enum MemoryOrigin: String, Codable, Sendable {
    case manual, userEdited, explicitUser, automatic

    var title: String {
        switch self {
        case .manual: "手动保存"
        case .userEdited: "用户编辑"
        case .explicitUser: "用户明确要求记住"
        case .automatic: "从用户陈述自动形成"
        }
    }
}

struct MemoryRevisionReference: Codable, Sendable, Equatable, Hashable {
    let memoryID: String
    let revisionID: String
}

struct MemorySource: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let conversationID: String?
    let messageID: String?
    let kind: MemoryOrigin
    var missing: Bool
    var conversationTitle: String? = nil
}

struct MemoryItem: Sendable, Equatable, Identifiable {
    let id: String
    let revisionID: String
    let content: String
    let origin: MemoryOrigin
    let factKey: String?
    let archived: Bool
    let createdAt: Date
    let updatedAt: Date
    let sources: [MemorySource]

    var reference: MemoryRevisionReference { .init(memoryID: id, revisionID: revisionID) }
}

struct MemorySettings: Sendable, Equatable {
    var enabled: Bool
    var automaticEnabled: Bool
    var generation: Int
}

struct MemoryContext: Sendable, Equatable {
    let reference: MemoryRevisionReference
    let content: String
}

struct MemoryFormationInput: Sendable {
    let runID: String
    let conversationID: String
    let messageID: String
    let text: String
    let sourceCreatedAt: Date
    let generation: Int
}
