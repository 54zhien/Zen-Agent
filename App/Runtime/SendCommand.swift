import Foundation

/// The complete input to a Parent Send.
///
/// Conversation settings do not yet persist a model binding, so the concrete
/// ProviderInstance and ModelID are deliberately supplied by the caller and frozen by
/// `ConversationRuntime` before anything is written.
struct SendCommand: Sendable, Equatable {
    var conversationID: String
    var text: String
    var references: [QuoteReference] = []

    var providerInstanceID: ProviderInstanceID
    var modelID: ModelID

    var maxProviderSteps: Int
    var submissionID: String
}

enum ConversationRuntimeError: Error, Equatable, Sendable {
    case invalidMaxProviderSteps(Int)
    case emptySubmissionID
    case submissionIDPayloadConflict(String)
    case providerInstanceBelongsToAnotherProvider(
        instanceID: ProviderInstanceID,
        expected: ProviderID,
        actual: ProviderID
    )
    case unsupportedModel(ModelID)
    case unsupportedTextModel(ModelID)
    case missingCredential(ProviderInstanceID)
    case credentialUnavailable(CredentialStatus)
}
