import Foundation

enum MCPProtocolVersion {
    static let modern = "2026-07-28"
    static let legacy = "2025-11-25"
}

enum MCPRequestBuilder {
    static func modern(
        endpoint: URL,
        method: String,
        id: String?,
        params: [String: JSONValue] = [:],
        bearerToken: SecretValue? = nil,
        parameterHeaders: [String: String] = [:]
    ) throws -> HTTPRequest {
        let metadata: [String: JSONValue] = [
            "io.modelcontextprotocol/protocolVersion": .string(MCPProtocolVersion.modern),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
            "io.modelcontextprotocol/clientInfo": .object([
                "name": .string("Zen Agent"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
            ])
        ]

        var requestParameters = params
        requestParameters["_meta"] = .object(metadata)
        var headers = baseHeaders
        headers["MCP-Protocol-Version"] = MCPProtocolVersion.modern
        headers["Mcp-Method"] = method
        if let name = nameValue(method: method, params: params) {
            headers["Mcp-Name"] = encodeHeaderValue(name)
        }
        for (name, value) in parameterHeaders {
            headers["Mcp-Param-\(name)"] = encodeHeaderValue(value)
        }
        if let bearerToken {
            headers["Authorization"] = "Bearer \(bearerToken.revealed)"
        }

        return try makeRequest(
            endpoint: endpoint,
            id: id,
            method: method,
            params: requestParameters,
            headers: headers
        )
    }

    static func parameterHeaders(
        arguments: [String: JSONValue],
        inputSchema: JSONValue
    ) -> [String: String] {
        guard let parameters = headerParameters(in: inputSchema) else { return [:] }
        var headers: [String: String] = [:]
        for parameter in parameters {
            guard let value = value(at: parameter.path, in: .object(arguments)),
                  let string = parameterValue(value, type: parameter.type) else { continue }
            headers[parameter.suffix] = string
        }
        return headers
    }

    static func hasValidHeaderParameters(in inputSchema: JSONValue) -> Bool {
        headerParameters(in: inputSchema) != nil
    }

    static func legacy(
        endpoint: URL,
        method: String,
        id: String?,
        params: [String: JSONValue] = [:],
        protocolVersion: String? = nil,
        sessionID: String? = nil,
        bearerToken: SecretValue? = nil
    ) throws -> HTTPRequest {
        var headers = baseHeaders
        if let protocolVersion {
            headers["MCP-Protocol-Version"] = protocolVersion
        }
        if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
        }
        if let bearerToken {
            headers["Authorization"] = "Bearer \(bearerToken.revealed)"
        }
        return try makeRequest(
            endpoint: endpoint,
            id: id,
            method: method,
            params: params,
            headers: headers
        )
    }

    private struct HeaderParameter {
        let path: [String]
        let suffix: String
        let type: String
    }

    private static let baseHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"
    ]

    private static func nameValue(method: String, params: [String: JSONValue]) -> String? {
        switch method {
        case "tools/call", "prompts/get":
            if case .string(let name) = params["name"] { return name }
        case "resources/read":
            if case .string(let uri) = params["uri"] { return uri }
        default:
            break
        }
        return nil
    }

    private static func headerParameters(in inputSchema: JSONValue) -> [HeaderParameter]? {
        guard case .object(let schema) = inputSchema else { return [] }
        var parameters: [HeaderParameter] = []
        var suffixes: Set<String> = []
        guard collectHeaderParameters(
            properties: schema["properties"],
            path: [],
            parameters: &parameters,
            suffixes: &suffixes
        ) else { return nil }
        return parameters
    }

    private static func collectHeaderParameters(
        properties value: JSONValue?,
        path: [String],
        parameters: inout [HeaderParameter],
        suffixes: inout Set<String>
    ) -> Bool {
        guard case .object(let properties)? = value else { return true }
        for (name, propertyValue) in properties {
            guard case .object(let property) = propertyValue else { continue }
            let propertyPath = path + [name]
            if let annotation = property["x-mcp-header"] {
                guard case .string(let suffix) = annotation,
                      isHeaderToken(suffix),
                      case .string(let type)? = property["type"],
                      ["string", "integer", "boolean"].contains(type),
                      suffixes.insert(suffix.lowercased()).inserted else { return false }
                parameters.append(HeaderParameter(path: propertyPath, suffix: suffix, type: type))
            } else if !collectHeaderParameters(
                properties: property["properties"],
                path: propertyPath,
                parameters: &parameters,
                suffixes: &suffixes
            ) {
                return false
            }
        }
        return true
    }

    private static func isHeaderToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let punctuation = "!#$%&'*+-.^_|~"
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return (65...90).contains(code)
                || (97...122).contains(code)
                || (48...57).contains(code)
                || code == 96
                || (code < 128 && punctuation.unicodeScalars.contains(scalar))
        }
    }

    private static func value(at path: [String], in root: JSONValue) -> JSONValue? {
        var value = root
        for component in path {
            guard case .object(let object) = value, let child = object[component] else { return nil }
            value = child
        }
        return value
    }

    private static func parameterValue(_ value: JSONValue, type: String) -> String? {
        switch (type, value) {
        case ("string", .string(let string)):
            string
        case ("integer", .number(let number)):
            String(format: "%.0f", number)
        case ("boolean", .bool(let boolean)):
            boolean ? "true" : "false"
        default:
            nil
        }
    }

    private static func encodeHeaderValue(_ value: String) -> String {
        let bytes = value.utf8
        let visibleASCII = bytes.allSatisfy { (0x20...0x7e).contains($0) }
        let hasEdgeWhitespace = value != value.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeEncoding = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        guard !visibleASCII || hasEdgeWhitespace || looksLikeEncoding else { return value }
        return "=?base64?\(Data(bytes).base64EncodedString())?="
    }

    private static func makeRequest(
        endpoint: URL,
        id: String?,
        method: String,
        params: [String: JSONValue],
        headers: [String: String]
    ) throws -> HTTPRequest {
        var body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params)
        ]
        if let id { body["id"] = .string(id) }
        let data = try JSONEncoder().encode(JSONValue.object(body))
        return HTTPRequest(method: .post, url: endpoint, headers: headers, body: data)
    }
}