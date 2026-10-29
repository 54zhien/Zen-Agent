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
            let credentialReference = MCPAuthenticationReference.credential(
                CredentialReference(id: "credential-reference", kind: .apiKey)
            )
            let authenticated = try registry.setAuthenticationReference(
                id: created.id,
                reference: credentialReference
            )
            #expect(authenticated.authenticationReference == credentialReference)
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
        #expect(persisted.authenticationReference == .credential(
            CredentialReference(id: "credential-reference", kind: .apiKey)
        ))

        let disabled = try reopenedRegistry.setEnabled(id: serverID, enabled: false)
        #expect(disabled.connectionState == .disabled)
        try reopenedRegistry.delete(id: serverID)
        #expect(try reopenedRegistry.list().isEmpty)
    }

    @Test("v25 server settings survive the v26 authentication reference migration")
    func v25ConfigurationSurvivesV26Migration() throws {
        let url = try Fixtures.scratchPath(name: "mcp-v25-to-v26.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let queue = try DatabaseQueue(path: url.path)
            try Migrations.makeMigrator().migrate(queue, upTo: "v25_mcp_server_registry")
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO mcpServer (id, displayName, endpoint, enabled, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [
                        "mcp-server-existing",
                        "Existing tools",
                        "https://mcp.example.test/rpc",
                        true,
                        Date(timeIntervalSince1970: 10),
                        Date(timeIntervalSince1970: 20)
                    ]
                )
            }
        }

        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let registry = MCPServerRegistry(store: store)
        let existing = try #require(registry.server(id: "mcp-server-existing"))
        #expect(existing.displayName == "Existing tools")
        #expect(existing.endpoint == "https://mcp.example.test/rpc")
        #expect(existing.enabled)
        #expect(existing.authenticationReference == nil)

        let reference = MCPAuthenticationReference.globalEnvironment(
            EnvironmentRevisionReference(variableID: "environment-variable", revisionID: "revision-2")
        )
        let updated = try registry.setAuthenticationReference(id: existing.id, reference: reference)
        #expect(updated.authenticationReference == reference)
    }}
