import Foundation

enum ToolIntentFailure: String, Error, Sendable {
    case invalidArguments, preparationFailed, malformedIntent, unsupportedVersion
    case legacyIntentRequiresReapproval, descriptorChanged, actionChanged, invalidScope
    case dependenciesChanged

    var resultContent: String { "Tool intent rejected: \(rawValue)." }
}

enum ToolIntentCodec {
    static func decodeForDisplay(_ json: String) throws -> ToolExecutionIntent {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).formatVersion
            guard version == 1 || version == 2 else { throw ToolIntentFailure.unsupportedVersion }
            return try decoder.decode(ToolExecutionIntent.self, from: data)
        } catch let failure as ToolIntentFailure {
            throw failure
        } catch {
            throw ToolIntentFailure.malformedIntent
        }
    }

    static func validate(_ intent: ToolExecutionIntent, descriptor: ToolDescriptor) throws {
        guard intent.formatVersion != 1 else { throw ToolIntentFailure.legacyIntentRequiresReapproval }
        guard intent.formatVersion == 2 else { throw ToolIntentFailure.unsupportedVersion }
        guard ToolPolicyIdentity.isValid(intent.toolID), ToolPolicyIdentity.isValid(intent.descriptorRevision),
              ToolPolicyIdentity.equals(intent.toolID, descriptor.id),
              ToolPolicyIdentity.equals(intent.descriptorRevision, descriptor.revision)
        else { throw ToolIntentFailure.descriptorChanged }
        guard let action = intent.policyAction, action.isKnown, ToolPolicyIdentity.isValid(action.actionID),
              ToolPolicyIdentity.equals(action.toolID, descriptor.id),
              ToolPolicyIdentity.equals(action.descriptorRevision, descriptor.revision)
        else { throw ToolIntentFailure.actionChanged }
        let registered = descriptor.actions.filter { ToolPolicyIdentity.equals($0.actionID, action.actionID) }
        guard registered.count == 1, matches(action, registered[0]) else { throw ToolIntentFailure.actionChanged }
        guard let resource = intent.resourceScope, let destination = intent.destinationScope,
              action.resourceRequirement.accepts(resource), action.egressRequirement.accepts(destination),
              resourceAliasMatches(resource, intent.targetIdentity),
              destinationAliasMatches(destination, intent.destinationIdentity)
        else { throw ToolIntentFailure.invalidScope }
        guard let object = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              let normalized = try? ToolArgumentJSON.normalizedObject(object),
              ToolPolicyIdentity.equals(normalized, intent.normalizedArgumentsJSON)
        else { throw ToolIntentFailure.invalidArguments }
    }

    /// Freezes the existing payload only after the trusted executor resolves its
    /// action and identities. Neither metadata nor resolved scopes come from UI.
    static func freeze(
        descriptor: ToolDescriptor,
        actionID: String,
        normalizedArgumentsJSON: String,
        resource: ToolResourceScope,
        destination: ToolDestinationScope,
        approvalDisclosure: ToolApprovalDisclosure? = nil
    ) throws -> ToolExecutionIntent {
        let actions = descriptor.actions.filter { ToolPolicyIdentity.equals($0.actionID, actionID) }
        guard actions.count == 1 else { throw ToolIntentFailure.actionChanged }
        let targetIdentity: String?
        switch resource {
        case .notRequired, .missing: targetIdentity = nil
        case .target(let id): targetIdentity = id
        case .file(let assetID, _, _): targetIdentity = assetID
        }
        let destinationIdentity: String?
        switch destination {
        case .notRequired, .missing: destinationIdentity = nil
        case .provider(_, let endpoint): destinationIdentity = endpoint
        }
        let intent = ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion, toolID: descriptor.id,
            descriptorRevision: descriptor.revision, normalizedArgumentsJSON: normalizedArgumentsJSON,
            targetIdentity: targetIdentity, destinationIdentity: destinationIdentity,
            approvalDisclosure: approvalDisclosure, policyAction: actions[0], resourceScope: resource,
            destinationScope: destination
        )
        try validate(intent, descriptor: descriptor)
        return intent
    }

    private struct Version: Decodable { let formatVersion: Int }

    private static func matches(_ a: ToolPolicyActionMetadata, _ b: ToolPolicyActionMetadata) -> Bool {
        // Aggregate Equatable has text semantics; authority identities use bytes.
        ToolPolicyIdentity.equals(a.toolID, b.toolID)
            && ToolPolicyIdentity.equals(a.actionID, b.actionID)
            && ToolPolicyIdentity.equals(a.descriptorRevision, b.descriptorRevision)
            && a.risk == b.risk && a.allowsAutomaticApproval == b.allowsAutomaticApproval
            && a.allowsConversationGrant == b.allowsConversationGrant
            && a.resourceRequirement == b.resourceRequirement && a.egressRequirement == b.egressRequirement
    }

    private static func resourceAliasMatches(_ scope: ToolResourceScope, _ alias: String?) -> Bool {
        switch scope {
        case .notRequired: return alias == nil
        case .missing: return false
        case .target(let id): return alias.map { ToolPolicyIdentity.equals(id, $0) } ?? false
        case .file(let asset, _, _): return alias.map { ToolPolicyIdentity.equals(asset, $0) } ?? false
        }
    }

    private static func destinationAliasMatches(_ scope: ToolDestinationScope, _ alias: String?) -> Bool {
        switch scope {
        case .notRequired: return alias == nil
        case .missing: return false
        case .provider(_, let endpoint): return alias.map { ToolPolicyIdentity.equals(endpoint, $0) } ?? false
        }
    }
}
