/// Shared effort vocabulary; availability belongs to each provider-owned model.
enum ThinkingEffort: String, Codable, CaseIterable, Sendable, Hashable {
    case low, medium, high, xhigh, max, ultra
}

extension ModelDescriptor {
    var supportedThinkingEfforts: [ThinkingEffort] {
        ThinkingEffort.allCases.filter { thinkingEfforts?.contains($0) == true }
    }
}

extension ModelProvider {
    /// Validate the selected model's option and freeze it before the Send commit.
    func makeRequestConfigSeed(instance: ProviderInstance, modelID: ModelID,
                               credentialBinding: CredentialBindingSnapshot,
                               thinkingEffort: ThinkingEffort?) throws -> RequestConfigSeed {
        if let thinkingEffort {
            guard descriptor(for: modelID, in: instance)?.supportedThinkingEfforts.contains(thinkingEffort) == true else {
                throw ProviderError.invalidParameters("Selected thinking effort is not supported by this model")
            }
        }
        var seed = try makeRequestConfigSeed(instance: instance, modelID: modelID,
            credentialBinding: credentialBinding)
        seed.formatVersion = RequestConfigSeed.currentFormatVersion
        seed.thinkingEffort = thinkingEffort
        return seed
    }
}