import Foundation

struct MCPServerRegistry: Sendable {
    private let store: PersistenceStore

    init(store: PersistenceStore) {
        self.store = store
    }

    func list() throws -> [MCPServer] {
        try store.mcpServers()
    }

    func server(id: String) throws -> MCPServer? {
        try store.mcpServer(id: id)
    }

    func create(displayName: String, endpoint: String) throws -> MCPServer {
        try store.createMCPServer(
            id: "mcp-server-\(UUID().uuidString)",
            displayName: displayName,
            endpoint: endpoint
        )
    }

    func update(id: String, displayName: String, endpoint: String) throws -> MCPServer {
        try store.updateMCPServer(id: id, displayName: displayName, endpoint: endpoint)
    }

    func setEnabled(id: String, enabled: Bool) throws -> MCPServer {
        try store.setMCPServerEnabled(id: id, enabled: enabled)
    }

    func setAuthenticationReference(
        id: String,
        reference: MCPAuthenticationReference?
    ) throws -> MCPServer {
        try store.setMCPServerAuthenticationReference(id: id, reference: reference)
    }

    func delete(id: String) throws {
        try store.deleteMCPServer(id: id)
    }
}