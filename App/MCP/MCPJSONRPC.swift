import Foundation

struct MCPJSONRPCError: Decodable, Sendable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct MCPJSONRPCResponse: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let result: JSONValue?
    let error: MCPJSONRPCError?
}

struct MCPServerCapabilities: Decodable, Sendable {
    let tools: JSONValue?
    let resources: JSONValue?
    let prompts: JSONValue?
}

struct MCPDiscoverResult: Decodable, Sendable {
    let resultType: String
    let supportedVersions: [String]
    let capabilities: MCPServerCapabilities
    let instructions: String?
    let meta: MCPServerResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case resultType, supportedVersions, capabilities, instructions
        case meta = "_meta"
    }
}

struct MCPServerResponseMetadata: Decodable, Sendable {
    let serverInfo: MCPServerInfo?

    enum CodingKeys: String, CodingKey {
        case serverInfo = "io.modelcontextprotocol/serverInfo"
    }
}

struct MCPLegacyInitializeResult: Decodable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
    let instructions: String?
}

struct MCPToolsListPage: Decodable, Sendable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?
}

struct MCPResourcesListPage: Decodable, Sendable {
    let resources: [MCPResourceDefinition]
    let nextCursor: String?
}

struct MCPPromptsListPage: Decodable, Sendable {
    let prompts: [MCPPromptDefinition]
    let nextCursor: String?
}

enum MCPJSONRPCDecoder {
    static func response(from body: Data, requestID: String) throws -> MCPJSONRPCResponse {
        let trimmed = body.drop { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
        }
        guard let first = trimmed.first else { throw MCPClientError.invalidResponse }
        if first == UInt8(ascii: "{") {
            return try matchingResponse(from: Data(trimmed), requestID: requestID)
        }

        var parser = SSEParser()
        var response: MCPJSONRPCResponse?
        for element in try parser.consume(body) {
            guard case .event(let event) = element else { continue }
            let data = Data(event.data.utf8)
            let candidate = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: data)
            if let candidate, candidate.id == .string(requestID) {
                response = candidate
            }
        }
        guard let response else { throw MCPClientError.invalidResponse }
        return response
    }

    static func errorResponse(from response: HTTPResponse) -> MCPJSONRPCError? {
        try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: response.body).error
    }

    static func requireResult(_ response: MCPJSONRPCResponse) throws -> JSONValue {
        if let error = response.error {
            throw MCPClientError.rpcError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw MCPClientError.invalidResponse }
        return result
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw MCPClientError.invalidResponse }
        return object
    }

    private static func matchingResponse(from body: Data, requestID: String) throws -> MCPJSONRPCResponse {
        let response = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: body)
        guard response.id == .string(requestID) else { throw MCPClientError.invalidResponse }
        return response
    }
}