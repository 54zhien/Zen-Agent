import Foundation
import GRDB

enum ImageInputExecutionRoute: String, Codable, Sendable, Equatable {
    case primaryVision
    case preprocess
}

/// The exact Image Input target captured before a Send is committed.
struct ImageInputExecutionSeed: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var providerID: ProviderID
    var adapterRevision: String
    var requestConfigSeed: RequestConfigSeed
    var capabilities: Set<ModelCapability>
    var imageVersionIDs: [String]
    var submissionDigest: String
    var route: ImageInputExecutionRoute

    init(
        providerID: ProviderID,
        adapterRevision: String,
        requestConfigSeed: RequestConfigSeed,
        capabilities: Set<ModelCapability>,
        imageVersionIDs: [String],
        submissionDigest: String,
        route: ImageInputExecutionRoute
    ) {
        formatVersion = Self.currentFormatVersion
        self.providerID = providerID
        self.adapterRevision = adapterRevision
        self.requestConfigSeed = requestConfigSeed
        self.capabilities = capabilities
        self.imageVersionIDs = imageVersionIDs
        self.submissionDigest = submissionDigest
        self.route = route
    }
}

/// The non-secret provider target that completed image processing for this Run.
struct ImageInputTargetProvenance: Codable, Sendable, Equatable {
    var providerInstanceID: String
    var adapterID: String
    var modelID: String
    /// A display-only endpoint identity. The complete frozen request URL belongs to the Run snapshot.
    var endpoint: String
    var configRevision: String

    static func displayEndpoint(from endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint),
              components.scheme != nil,
              components.host != nil else { return "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }
}

/// A successfully completed image-processing result tied to the exact Run input.
///
/// Rows exist only after a complete response is available. An absent result does not
/// prove that a request was never dispatched; AgentStep attempt state owns that decision.
struct ImageInputResultRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "imageInputResult"

    var runID: String
    var messageID: String
    var versionID: String
    /// Internal model context derived from the attachment, never a timeline message.
    var internalContext: String
    var targetProviderInstanceID: String
    var targetAdapterID: String
    var targetModelID: String
    var targetEndpoint: String
    var targetConfigRevision: String
    var completedAt: Date

    var targetProvenance: ImageInputTargetProvenance {
        ImageInputTargetProvenance(
            providerInstanceID: targetProviderInstanceID,
            adapterID: targetAdapterID,
            modelID: targetModelID,
            endpoint: targetEndpoint,
            configRevision: targetConfigRevision
        )
    }

    init(
        runID: String,
        messageID: String,
        versionID: String,
        internalContext: String,
        targetProvenance: ImageInputTargetProvenance,
        completedAt: Date
    ) {
        self.runID = runID
        self.messageID = messageID
        self.versionID = versionID
        self.internalContext = internalContext
        targetProviderInstanceID = targetProvenance.providerInstanceID
        targetAdapterID = targetProvenance.adapterID
        targetModelID = targetProvenance.modelID
        targetEndpoint = targetProvenance.endpoint
        targetConfigRevision = targetProvenance.configRevision
        self.completedAt = completedAt
    }
}
