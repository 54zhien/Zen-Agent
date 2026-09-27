import Foundation

/// The non-secret execution context frozen while a run is preparing.
///
/// This is intentionally separate from both `RequestConfigSeed` and mutable provider
/// configuration. The seed identifies where and with which credential the request goes;
/// this value identifies the prompt, capabilities and tools that the run is allowed to
/// execute with.
struct RunExecutionSnapshot: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    enum FormatError: Error, Equatable, Sendable {
        case unversioned
        case unsupportedVersion(Int)
        case malformedCurrentVersion(Int)
    }

    var formatVersion: Int

    var providerID: ProviderID
    var providerAdapterRevision: String

    var prompt: PromptExecutionSnapshot
    var modelCapabilities: Set<ModelCapability>
    var exposedTools: [ToolExposureSnapshot]

    var maxProviderSteps: Int

    init(
        formatVersion: Int = RunExecutionSnapshot.currentFormatVersion,
        providerID: ProviderID,
        providerAdapterRevision: String,
        prompt: PromptExecutionSnapshot,
        modelCapabilities: Set<ModelCapability>,
        exposedTools: [ToolExposureSnapshot],
        maxProviderSteps: Int
    ) {
        self.formatVersion = formatVersion
        self.providerID = providerID
        self.providerAdapterRevision = providerAdapterRevision
        self.prompt = prompt
        self.modelCapabilities = modelCapabilities
        self.exposedTools = exposedTools
        self.maxProviderSteps = maxProviderSteps
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case providerID
        case providerAdapterRevision
        case prompt
        case modelCapabilities
        case exposedTools
        case maxProviderSteps
    }

    /// Reads the version before the payload and refuses formats this build cannot
    /// interpret. Missing and malformed current fields remain distinct diagnoses.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let version = try? container.decode(Int.self, forKey: .formatVersion) else {
            throw FormatError.unversioned
        }
        guard version == Self.currentFormatVersion else {
            throw FormatError.unsupportedVersion(version)
        }

        do {
            providerID = try container.decode(ProviderID.self, forKey: .providerID)
            providerAdapterRevision = try container.decode(String.self, forKey: .providerAdapterRevision)
            prompt = try container.decode(PromptExecutionSnapshot.self, forKey: .prompt)
            modelCapabilities = try container.decode(Set<ModelCapability>.self, forKey: .modelCapabilities)
            exposedTools = try container.decode([ToolExposureSnapshot].self, forKey: .exposedTools)
            maxProviderSteps = try container.decode(Int.self, forKey: .maxProviderSteps)
        } catch {
            throw FormatError.malformedCurrentVersion(version)
        }
        formatVersion = version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(providerAdapterRevision, forKey: .providerAdapterRevision)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(modelCapabilities, forKey: .modelCapabilities)
        try container.encode(exposedTools, forKey: .exposedTools)
        try container.encode(maxProviderSteps, forKey: .maxProviderSteps)
    }
}

struct PromptExecutionSnapshot: Codable, Sendable, Equatable {
    /// Built-in template revision IDs. The adapter instructions are frozen text.
    var runtimeSafetyBaseline: String
    var zenCore: String
    var providerAdapterInstructions: String
    var soulVersionID: String?

    init(
        runtimeSafetyBaseline: String,
        zenCore: String,
        providerAdapterInstructions: String,
        soulVersionID: String? = nil
    ) {
        self.runtimeSafetyBaseline = runtimeSafetyBaseline
        self.zenCore = zenCore
        self.providerAdapterInstructions = providerAdapterInstructions
        self.soulVersionID = soulVersionID
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeSafetyBaseline
        case zenCore
        case providerAdapterInstructions
        case soulVersionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeSafetyBaseline = try container.decode(String.self, forKey: .runtimeSafetyBaseline)
        zenCore = try container.decode(String.self, forKey: .zenCore)
        providerAdapterInstructions = try container.decode(String.self, forKey: .providerAdapterInstructions)
        // v1 snapshots written before Soul did not contain this optional identity.
        soulVersionID = try container.decodeIfPresent(String.self, forKey: .soulVersionID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeSafetyBaseline, forKey: .runtimeSafetyBaseline)
        try container.encode(zenCore, forKey: .zenCore)
        try container.encode(providerAdapterInstructions, forKey: .providerAdapterInstructions)
        try container.encode(soulVersionID, forKey: .soulVersionID)
    }
}

struct ToolExposureSnapshot: Codable, Sendable, Equatable {
    var toolID: String
    var descriptorRevision: String
    var displayName: String
    var description: String
    var inputSchema: JSONValue
}
