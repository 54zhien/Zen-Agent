import GRDB

enum ToolSystemConsentPhase: String, Codable, Sendable { case waiting, requesting, completed, declined }

/// Interaction facts, never an alternative truth for the current OS permission.
struct ToolSystemConsentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "toolSystemConsent"
    let toolCallID: String
    let attempt: Int
    let intentBinding: String
    let capabilityDescription: String
    var phase: ToolSystemConsentPhase
    var requestID: String?
    var requestOwner: String?
}
