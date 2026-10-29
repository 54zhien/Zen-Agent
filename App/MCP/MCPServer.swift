import Foundation

enum MCPServerRegistryError: Error, Equatable, Sendable {
    case notFound
}

enum MCPServerConnectionState: Equatable, Sendable {
    case disabled
    case disconnected
    case connecting
    case connected
    case authenticationRequired
    case failed
}

struct MCPServer: Equatable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let enabled: Bool
    let createdAt: Date
    let updatedAt: Date
    let authenticationReference: MCPAuthenticationReference?

    init(
        id: String,
        displayName: String,
        endpoint: String,
        enabled: Bool,
        createdAt: Date,
        updatedAt: Date,
        authenticationReference: MCPAuthenticationReference? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.authenticationReference = authenticationReference
    }

    var connectionState: MCPServerConnectionState {
        enabled ? .disconnected : .disabled
    }
}