import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("MCP Server Registry")
struct MCPServerRegistryTests {
    @Test("server configuration CRUD survives a v24 database reopening")
    func configurationCRUDSurvivesReopening() throws {
        let url = try Fixtures.scratchPath(name: "mcp-registry.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let queue = try DatabaseQueue(path: url.path)
            try Migrations.makeMigrator().migrate(queue, upTo: "v24_agent_step_protocol_response")
        }

        let serverID = try {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            #expect(try store.database.read { try $0.tableExists("mcpServer") })

            let registry = MCPServerRegistry(store: store)
            let created = try registry.create(
                displayName: "Local tools",
                endpoint: "https://mcp.example.invalid/api"
            )
            #expect(created.connectionState == .disabled)
            #expect(try registry.list().map(\.id) == [created.id])

            let edited = try registry.update(
                id: created.id,
                displayName: "Research tools",
                endpoint: "https://mcp.example.invalid/v2"
            )
            #expect(edited.id == created.id)
            #expect(edited.displayName == "Research tools")
            #expect(edited.endpoint == "https://mcp.example.invalid/v2")

            let enabled = try registry.setEnabled(id: created.id, enabled: true)
            #expect(enabled.connectionState == .disconnected)
            return created.id
        }()

        let reopenedStore = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let reopenedRegistry = MCPServerRegistry(store: reopenedStore)
        let persisted = try #require(reopenedRegistry.list().first)
        #expect(persisted.id == serverID)
        #expect(persisted.displayName == "Research tools")
        #expect(persisted.endpoint == "https://mcp.example.invalid/v2")
        #expect(persisted.enabled)
        #expect(persisted.connectionState == .disconnected)

        let disabled = try reopenedRegistry.setEnabled(id: serverID, enabled: false)
        #expect(disabled.connectionState == .disabled)
        try reopenedRegistry.delete(id: serverID)
        #expect(try reopenedRegistry.list().isEmpty)
    }
}
