import Foundation

enum MCPServerRegistryError: Error, Equatable, Sendable {
    case notFound
}

enum MCPServerConnectionState: Equatable, Sendable {
    case disabled
    case disconnected
}

struct MCPServer: Equatable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let enabled: Bool
    let createdAt: Date
    let updatedAt: Date

    var connectionState: MCPServerConnectionState {
        enabled ? .disconnected : .disabled
    }
}
