import Foundation
import GRDB

extension PersistenceStore {
    func mcpServers() throws -> [MCPServer] {
        try database.read { db in
            try MCPServerRecord.fetchAll(
                db,
                sql: "SELECT * FROM mcpServer ORDER BY createdAt, id"
            ).map(\.server)
        }
    }

    func createMCPServer(
        id: String,
        displayName: String,
        endpoint: String,
        at now: Date = Date()
    ) throws -> MCPServer {
        let record = MCPServerRecord(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            enabled: false,
            createdAt: now,
            updatedAt: now
        )
        return try database.write { db in
            try record.insert(db)
            return record.server
        }
    }

    func updateMCPServer(
        id: String,
        displayName: String,
        endpoint: String,
        at now: Date = Date()
    ) throws -> MCPServer {
        try database.write { db in
            guard var record = try MCPServerRecord.fetchOne(db, key: id) else {
                throw MCPServerRegistryError.notFound
            }
            record.displayName = displayName
            record.endpoint = endpoint
            record.updatedAt = now
            try record.update(db)
            return record.server
        }
    }

    func setMCPServerEnabled(id: String, enabled: Bool, at now: Date = Date()) throws -> MCPServer {
        try database.write { db in
            guard var record = try MCPServerRecord.fetchOne(db, key: id) else {
                throw MCPServerRegistryError.notFound
            }
            record.enabled = enabled
            record.updatedAt = now
            try record.update(db)
            return record.server
        }
    }

    func deleteMCPServer(id: String) throws {
        try database.write { db in
            guard let record = try MCPServerRecord.fetchOne(db, key: id) else {
                throw MCPServerRegistryError.notFound
            }
            try record.delete(db)
        }
    }
}
