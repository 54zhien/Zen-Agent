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
    var authenticationReferenceType: String?
    var authenticationReferenceID: String?
    var authenticationReferenceDetail: String?

    var server: MCPServer {
        MCPServer(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
            authenticationReference: authenticationReference
        )
    }

    var authenticationReference: MCPAuthenticationReference? {
        switch authenticationReferenceType {
        case "credential":
            guard let authenticationReferenceID,
                  let authenticationReferenceDetail,
                  let kind = CredentialKind(rawValue: authenticationReferenceDetail) else { return nil }
            return .credential(CredentialReference(id: authenticationReferenceID, kind: kind))
        case "globalEnvironment":
            guard let authenticationReferenceID, let authenticationReferenceDetail else { return nil }
            return .globalEnvironment(EnvironmentRevisionReference(
                variableID: authenticationReferenceID,
                revisionID: authenticationReferenceDetail
            ))
        default:
            return nil
        }
    }

    mutating func setAuthenticationReference(_ reference: MCPAuthenticationReference?) {
        switch reference {
        case .credential(let credential):
            authenticationReferenceType = "credential"
            authenticationReferenceID = credential.id
            authenticationReferenceDetail = credential.kind.rawValue
        case .globalEnvironment(let environment):
            authenticationReferenceType = "globalEnvironment"
            authenticationReferenceID = environment.variableID
            authenticationReferenceDetail = environment.revisionID
        case nil:
            authenticationReferenceType = nil
            authenticationReferenceID = nil
            authenticationReferenceDetail = nil
        }
    }
}