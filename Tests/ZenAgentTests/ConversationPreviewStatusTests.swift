import Testing

@testable import ZenAgent

@Suite("Conversation preview status")
struct ConversationPreviewStatusTests {
    struct Case: Sendable {
        let state: RunState
        let reason: EndReason?
        let expected: ConversationCardStatus?
        let reasoningAllowed: Bool
        init(_ state: RunState, _ expected: ConversationCardStatus?,
             reason: EndReason? = nil, reasoningAllowed: Bool = false) {
            self.state = state
            self.reason = reason
            self.expected = expected
            self.reasoningAllowed = reasoningAllowed
        }
    }

    @Test("status derives from business projection and explicit visible reasoning permission", arguments: [
        Case(.preparing, .generating), Case(.requestingModel, .generating),
        Case(.streaming, .generating), Case(.continuing, .generating),
        Case(.stopping, .generating), Case(.suspended, .generating), Case(.recovering, .generating),
        Case(.streaming, .reasoningVisible, reasoningAllowed: true),
        Case(.toolRequested, .tool), Case(.executingTools, .tool), Case(.waitingForApproval, .approval),
        Case(.completed, nil, reason: .completed),
        Case(.cancelled, .cancelled, reason: .cancelledByUser),
        Case(.cancelled, .failed),
        Case(.failed, .failed, reason: .providerFailed),
        Case(.failed, .authenticationRequired, reason: .credentialExpired),
        Case(.failed, .failed, reason: .totalTimeout), Case(.failed, .failed, reason: .toolOutcomeUnknown)
    ])
    func mapping(input: Case) {
        let projection = RunProjection(runID: "preview-run", state: input.state, endReason: input.reason)
        #expect(ConversationCardStatus.derive(from: projection,
            visibleReasoningAllowed: input.reasoningAllowed) == input.expected)
    }

    @Test("a card without a Run does not invent a running status")
    func noRunHasNoStatus() { #expect(ConversationCardStatus.derive(from: nil) == nil) }
}
