import Foundation
import GRDB

struct MemoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "memoryRecord"
    let id: String
    var currentRevisionID: String
    var state: String
    var origin: MemoryOrigin
    var factKey: String?
    let createdAt: Date
    var updatedAt: Date
}

struct MemoryRevisionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "memoryRevision"
    let id: String
    let memoryID: String
    let content: String
    let createdAt: Date
}

struct MemorySourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "memorySource"
    let id: String
    let memoryID: String
    let conversationID: String?
    let messageID: String?
    let kind: MemoryOrigin
    let missing: Bool
    let createdAt: Date

    var source: MemorySource {
        .init(id: id, conversationID: conversationID, messageID: messageID, kind: kind, missing: missing)
    }
}
