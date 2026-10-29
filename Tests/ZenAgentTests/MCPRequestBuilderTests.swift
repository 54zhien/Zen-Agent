import Foundation
import Testing
@testable import ZenAgent

@Suite("MCP Streamable HTTP request construction")
struct MCPRequestBuilderTests {
    @Test("modern discovery sends the negotiated version in headers and request metadata")
    func modernDiscoveryCarriesVersionMetadata() throws {
        let request = try MCPRequestBuilder.modern(
            endpoint: URL(string: "https://mcp.example.test/rpc")!,
            method: "server/discover",
            id: "discover-1"
        )

        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "application/json, text/event-stream")
        #expect(request.headers["MCP-Protocol-Version"] == MCPProtocolVersion.modern)
        #expect(request.headers["Mcp-Method"] == "server/discover")
        #expect(request.headers["Mcp-Name"] == nil)

        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? String == "discover-1")
        #expect(object["method"] as? String == "server/discover")
        let params = try #require(object["params"] as? [String: Any])
        let metadata = try #require(params["_meta"] as? [String: Any])
        #expect(metadata["io.modelcontextprotocol/protocolVersion"] as? String == MCPProtocolVersion.modern)
        #expect(metadata["io.modelcontextprotocol/clientCapabilities"] != nil)
        let clientInfo = try #require(metadata["io.modelcontextprotocol/clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "Zen Agent")
        #expect(clientInfo["version"] as? String != nil)
    }

    @Test("modern call binds Mcp-Name to the server-local tool name")
    func modernCallNamesTheTargetTool() throws {
        let request = try MCPRequestBuilder.modern(
            endpoint: URL(string: "https://mcp.example.test/rpc")!,
            method: "tools/call",
            id: "call-1",
            params: [
                "name": .string("lookup"),
                "arguments": .object(["query": .string("weather")])
            ],
            bearerToken: SecretValue("test-bearer")
        )

        #expect(request.headers["Mcp-Method"] == "tools/call")
        #expect(request.headers["Mcp-Name"] == "lookup")
        #expect(request.headers["Authorization"] == "Bearer test-bearer")
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["name"] as? String == "lookup")
        let metadata = try #require(params["_meta"] as? [String: Any])
        #expect(metadata["io.modelcontextprotocol/protocolVersion"] as? String == MCPProtocolVersion.modern)
    }

    @Test("legacy request carries the negotiated session without modern metadata")
    func legacyRequestCarriesSessionAndVersion() throws {
        let request = try MCPRequestBuilder.legacy(
            endpoint: URL(string: "https://mcp.example.test/rpc")!,
            method: "tools/list",
            id: "list-1",
            protocolVersion: MCPProtocolVersion.legacy,
            sessionID: "session-1"
        )

        #expect(request.headers["MCP-Protocol-Version"] == MCPProtocolVersion.legacy)
        #expect(request.headers["Mcp-Session-Id"] == "session-1")
        #expect(request.headers["Mcp-Method"] == nil)
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["method"] as? String == "tools/list")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["_meta"] == nil)
    }
}
