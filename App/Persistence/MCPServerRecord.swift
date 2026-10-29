import Foundation
import GRDB

struct MCPServerRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "mcpServer"

    var id: String
    var displayName: String
    var endpoint: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    var server: MCPServer {
        MCPServer(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
