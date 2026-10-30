import Foundation

/// The non-secret execution context frozen while a run is preparing.
///
/// This is intentionally separate from both `RequestConfigSeed` and mutable provider
/// configuration. The seed identifies where and with which credential the request goes;
/// this value identifies the prompt, capabilities and tools that the run is allowed to
/// execute with.
struct RunExecutionSnapshot: Codable, Sendable, Equatable {
    // Reject workflow semantics this build cannot interpret; keep v1-v3 readable.
    static let currentFormatVersion = 4

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
    var mcpServerDependencies: [MCPServerDependencyIdentity]
    var delegation: DelegationExecutionSnapshot?

    func permitsTool(_ descriptor: ToolDescriptor) -> Bool {
        modelCapabilities.contains(.tools) && exposedTools.contains {
            $0.toolID == descriptor.id && $0.descriptorRevision == descriptor.revision
        }
    }

    var maxProviderSteps: Int

    init(
        formatVersion: Int = RunExecutionSnapshot.currentFormatVersion,
        providerID: ProviderID,
        providerAdapterRevision: String,
        prompt: PromptExecutionSnapshot,
        modelCapabilities: Set<ModelCapability>,
        exposedTools: [ToolExposureSnapshot],
        mcpServerDependencies: [MCPServerDependencyIdentity] = [],
        maxProviderSteps: Int,
        delegation: DelegationExecutionSnapshot? = nil
    ) {
        self.formatVersion = formatVersion
        self.providerID = providerID
        self.providerAdapterRevision = providerAdapterRevision
        self.prompt = prompt
        self.modelCapabilities = modelCapabilities
        self.exposedTools = exposedTools
        self.mcpServerDependencies = mcpServerDependencies
        self.delegation = delegation
        self.maxProviderSteps = maxProviderSteps
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case providerID
        case providerAdapterRevision
        case prompt
        case modelCapabilities
        case exposedTools
        case mcpServerDependencies
        case maxProviderSteps
        case delegation
    }

    /// Reads the version before the payload and refuses formats this build cannot
    /// interpret. Missing and malformed current fields remain distinct diagnoses.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let version = try? container.decode(Int.self, forKey: .formatVersion) else {
            throw FormatError.unversioned
        }
        guard version == 1 || version == 2 || version == 3 || version == Self.currentFormatVersion else {
            throw FormatError.unsupportedVersion(version)
        }

        do {
            providerID = try container.decode(ProviderID.self, forKey: .providerID)
            providerAdapterRevision = try container.decode(String.self, forKey: .providerAdapterRevision)
            prompt = try container.decode(PromptExecutionSnapshot.self, forKey: .prompt)
            guard version != 1 || prompt.skillReferences.isEmpty else { throw FormatError.malformedCurrentVersion(version) }
            modelCapabilities = try container.decode(Set<ModelCapability>.self, forKey: .modelCapabilities)
            exposedTools = try container.decode([ToolExposureSnapshot].self, forKey: .exposedTools)
            if version >= 3 {
                mcpServerDependencies = try container.decode([MCPServerDependencyIdentity].self, forKey: .mcpServerDependencies)
                let serverIDs = mcpServerDependencies.map(\.serverID)
                guard Set(serverIDs).count == serverIDs.count,
                      mcpServerDependencies == mcpServerDependencies.sorted(by: { $0.serverID < $1.serverID }) else {
                    throw FormatError.malformedCurrentVersion(version)
                }
            } else {
                mcpServerDependencies = []
            }
            delegation = version >= 4
                ? try container.decodeIfPresent(DelegationExecutionSnapshot.self, forKey: .delegation)
                : nil
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
        if formatVersion >= 3 {
            try container.encode(mcpServerDependencies, forKey: .mcpServerDependencies)
        }
        try container.encode(maxProviderSteps, forKey: .maxProviderSteps)
        if formatVersion >= 4 {
            try container.encodeIfPresent(delegation, forKey: .delegation)
        }
    }
}

enum DelegationModelPolicy: String, Codable, Sendable, Equatable {
    case followParent
}

enum DelegationEnvironmentInheritance: String, Codable, Sendable, Equatable {
    case none
}

/// The policy a Parent freezes during preparing and every Child reads from that
/// Parent revision. This increment deliberately supports only an empty Environment
/// inheritance set; it has no mapping source or precedence rule to reinterpret.
struct DelegationExecutionSnapshot: Codable, Sendable, Equatable {
    let revision: Int64
    let enabled: Bool
    let maxDepth: Int
    let maxConcurrentChildren: Int
    let modelPolicy: DelegationModelPolicy
    let environmentInheritance: DelegationEnvironmentInheritance

    init(configuration: DelegationRuntimeConfiguration) {
        revision = configuration.revision
        enabled = configuration.enabled
        maxDepth = 1
        maxConcurrentChildren = 1
        modelPolicy = .followParent
        environmentInheritance = .none
    }
}

struct PromptExecutionSnapshot: Codable, Sendable, Equatable {
    /// Built-in template revision IDs. The adapter instructions are frozen text.
    var runtimeSafetyBaseline: String
    var zenCore: String
    var providerAdapterInstructions: String
    var soulVersionID: String?
    var memoryReferences: [MemoryRevisionReference] = []
    var skillReferences: [SkillActivationReference] = []

    init(
        runtimeSafetyBaseline: String,
        zenCore: String,
        providerAdapterInstructions: String,
        soulVersionID: String? = nil,
        memoryReferences: [MemoryRevisionReference] = [],
        skillReferences: [SkillActivationReference] = []
    ) {
        self.runtimeSafetyBaseline = runtimeSafetyBaseline
        self.zenCore = zenCore
        self.providerAdapterInstructions = providerAdapterInstructions
        self.soulVersionID = soulVersionID
        self.memoryReferences = memoryReferences
        self.skillReferences = skillReferences
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeSafetyBaseline
        case zenCore
        case providerAdapterInstructions
        case soulVersionID
        case memoryReferences
        case skillReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeSafetyBaseline = try container.decode(String.self, forKey: .runtimeSafetyBaseline)
        zenCore = try container.decode(String.self, forKey: .zenCore)
        providerAdapterInstructions = try container.decode(String.self, forKey: .providerAdapterInstructions)
        // v1 snapshots written before Soul did not contain this optional identity.
        soulVersionID = try container.decodeIfPresent(String.self, forKey: .soulVersionID)
        memoryReferences = try container.decodeIfPresent([MemoryRevisionReference].self, forKey: .memoryReferences) ?? []
        skillReferences = try container.decodeIfPresent([SkillActivationReference].self, forKey: .skillReferences) ?? []
        guard SkillActivationReference.areWellFormed(skillReferences) else {
            throw DecodingError.dataCorruptedError(forKey: .skillReferences, in: container, debugDescription: "Invalid Skill references")
        }
        guard memoryReferences.count <= 6, Set(memoryReferences).count == memoryReferences.count,
              memoryReferences.allSatisfy({ !$0.memoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.revisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.memoryID.utf8.count <= 128 && $0.revisionID.utf8.count <= 128 }) else {
            throw DecodingError.dataCorruptedError(forKey: .memoryReferences, in: container,
                debugDescription: "Invalid Memory revision references")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeSafetyBaseline, forKey: .runtimeSafetyBaseline)
        try container.encode(zenCore, forKey: .zenCore)
        try container.encode(providerAdapterInstructions, forKey: .providerAdapterInstructions)
        try container.encode(soulVersionID, forKey: .soulVersionID)
        if !memoryReferences.isEmpty { try container.encode(memoryReferences, forKey: .memoryReferences) }
        if !skillReferences.isEmpty { try container.encode(skillReferences, forKey: .skillReferences) }
    }
}

struct ToolExposureSnapshot: Codable, Sendable, Equatable {
    var toolID: String
    var descriptorRevision: String
    var displayName: String
    var description: String
    var inputSchema: JSONValue
}
