import Testing

@testable import ZenAgent

@Suite("Tool Policy temporal authorization")
struct ToolPolicyTemporalTests {
    let rules = ToolPolicyEvaluatorTests()
    let scopes = ToolPolicyScopeTests()

    @Test func tighteningRevokesUndispatchedAllowance() {
        let creation = rules.policy(mode: .alwaysAllow)
        let grants = [once(), scopes.grant()]
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .deny, createdPolicy: creation, grants: grants)) == .deny(.globalDeny))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(cap: .deny, mode: .alwaysAllow, createdPolicy: creation, grants: grants)) == .deny(.hardDeny))
    }

    @Test(arguments: [ToolPolicyAdmissionDisposition.needsApproval, .denied])
    func settingsWideningDoesNotReleaseWaitingCall(admission: ToolPolicyAdmissionDisposition) {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, createdPolicy: rules.policy(), admission: admission)) == .needsApproval(.priorApprovalRequired))
    }

    @Test func explicitApprovalCanAuthorizeOriginalWaitingCall() {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, createdPolicy: rules.policy(), admission: .needsApproval, grants: [once()])) == .allow(.onceGrant))
    }

    @Test func onceCannotAuthorizeAnotherCallOrRun() {
        for call in [scopes.call(callID: "next"), scopes.call(runID: "next-run"), scopes.call(binding: "new-intent")] {
            #expect(ToolPolicyEvaluator.evaluate(rules.input(call: call, grants: [once()])) == .needsApproval(.noApplicableGrant))
        }
    }

    @Test func onceIsUnavailableAfterTerminal() {
        let terminal = scopes.call(available: false)
        #expect(!ToolGrantScopeMatcher.matches(grant: once(), call: terminal))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(call: terminal, grants: [once()])) == .deny(.authorizationUnavailable))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, call: terminal)) == .deny(.authorizationUnavailable))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(grants: [once(validity: .consumed)])) == .needsApproval(.noApplicableGrant))
    }

    @Test(arguments: [ToolGrantValidity.revoked, .active])
    func revokedConversationGrantDoesNotReturnAfterPolicyWidening(validity: ToolGrantValidity) {
        let widened = rules.policy(mode: .alwaysAllow, epoch: 1)
        let old = scopes.grant(validity: validity)
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(), currentPolicy: widened, grants: [old])) == .needsApproval(.priorApprovalRequired))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(), currentPolicy: widened, grants: [old, once(epoch: 1)])) == .allow(.onceGrant))
    }

    @Test func approvalDisplayOwnerDoesNotChangeGrantSubject() {
        let displayOwner = "conversation"
        let runCall = scopes.call(subject: .run("run"))
        let displayedGrant = scopes.grant(subject: .parentConversation(displayOwner))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(call: runCall, grants: [displayedGrant])) == .needsApproval(.noApplicableGrant))
        let ownedGrant = scopes.grant(subject: .run("run"))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(call: runCall, grants: [ownedGrant])) == .allow(.conversationGrant))
    }

    @Test func destinationOrVersionChangeCannotReuseApproval() {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(resolvedResource: .file(assetID: "asset", versionID: "v2", contentIdentity: "new-digest"), grants: [once()])) == .dependencyChanged(.resourceChanged))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(resolvedDestination: .provider(instanceID: "provider", endpointIdentity: "new-endpoint"), grants: [once()])) == .dependencyChanged(.destinationChanged))
    }

    @Test func subjectTerminationInvalidatesActiveGrant() {
        let inactive = scopes.call(subjectAvailable: false)
        #expect(!ToolGrantScopeMatcher.matches(grant: scopes.grant(), call: inactive))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(call: inactive, grants: [scopes.grant()])) == .deny(.subjectUnavailable))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, call: inactive)) == .deny(.subjectUnavailable))
    }

    @Test func tighteningThenWideningDoesNotRestoreAutomaticAdmission() {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(mode: .alwaysAllow), currentPolicy: rules.policy(mode: .alwaysAllow, epoch: 1))) == .needsApproval(.priorApprovalRequired))
    }

    @Test func anotherCallsConversationApprovalDoesNotReleaseWaitingCall() {
        let otherOrigin = ToolGrantApprovalBinding(toolCallID: "other", agentRunID: "run", intentBinding: "other-intent")
        let grant = scopes.grant(issuedFor: otherOrigin)
        #expect(ToolPolicyEvaluator.evaluate(rules.input(admission: .needsApproval, grants: [grant])) == .needsApproval(.priorApprovalRequired))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(admission: .needsApproval, grants: [scopes.grant(issuedFor: nil)])) == .needsApproval(.priorApprovalRequired))
        let later = scopes.call(callID: "later", runID: "later-run", binding: "later-intent")
        #expect(ToolPolicyEvaluator.evaluate(rules.input(call: later, grants: [grant])) == .allow(.conversationGrant))
    }

    @Test func tighteningNeedsThisCallsNewConversationApproval() {
        let current = rules.policy(epoch: 1)
        let otherOrigin = ToolGrantApprovalBinding(toolCallID: "other", agentRunID: "run", intentBinding: "other-intent")
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(), currentPolicy: current, grants: [scopes.grant(epoch: 1, issuedFor: otherOrigin)])) == .needsApproval(.priorApprovalRequired))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(), currentPolicy: current, grants: [scopes.grant(epoch: 1)])) == .allow(.conversationGrant))
    }

    @Test func explicitConversationApprovalCanAuthorizeOriginalWaitingCall() {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, createdPolicy: rules.policy(), admission: .needsApproval, grants: [scopes.grant()])) == .allow(.conversationGrant))
    }

    @Test(arguments: [UInt64(0), UInt64(2)])
    func grantRevocationEpochMustBeCurrent(epoch: UInt64) {
        let current = rules.policy(epoch: 1)
        #expect(ToolPolicyEvaluator.evaluate(rules.input(currentPolicy: current, grants: [scopes.grant(epoch: epoch), once(epoch: epoch)])) == .needsApproval(.noApplicableGrant))
    }

    @Test func staleCurrentPolicySnapshotCannotAuthorize() {
        #expect(ToolPolicyEvaluator.evaluate(rules.input(createdPolicy: rules.policy(mode: .alwaysAllow, epoch: 2), currentPolicy: rules.policy(mode: .alwaysAllow, epoch: 1), grants: [once(epoch: 1)])) == .dependencyChanged(.stalePolicySnapshot))
    }

    @Test func repreparedIntentCannotInheritAutomaticAdmission() {
        let prepared = scopes.call(binding: "new-intent")
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, admissionBinding: "intent", call: prepared)) == .needsApproval(.priorApprovalRequired))
        let approved = scopes.grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "new-intent"))
        #expect(ToolPolicyEvaluator.evaluate(rules.input(mode: .alwaysAllow, admissionBinding: "intent", call: prepared, grants: [approved])) == .allow(.onceGrant))
    }

    @Test func wideningMayAdmitANewCall() {
        let current = rules.policy(mode: .alwaysAllow, epoch: 1)
        let future = scopes.call(callID: "next", runID: "next-run", binding: "next-intent")
        #expect(ToolPolicyEvaluator.evaluate(rules.input(currentPolicy: current, call: future, grants: [scopes.grant(validity: .revoked)])) == .allow(.globalPolicy))
    }

    @Test func changedRevisionNeedsFreshApprovalButDoesNotBlockItForever() {
        let revised = scopes.call(revision: "r2", binding: "new-intent")
        let action = rules.metadata(revision: "r2")
        let current = rules.policy(revision: "r2", mode: .alwaysAllow)
        let creation = rules.policy(mode: .alwaysAllow)
        #expect(ToolPolicyEvaluator.evaluate(rules.input(action: action, createdPolicy: creation, admissionBinding: "intent", currentPolicy: current, call: revised)) == .needsApproval(.priorApprovalRequired))
        let approved = scopes.grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "new-intent"), revision: "r2")
        #expect(ToolPolicyEvaluator.evaluate(rules.input(action: action, createdPolicy: creation, admissionBinding: "intent", currentPolicy: current, call: revised, grants: [approved])) == .allow(.onceGrant))
    }

    func once(epoch: UInt64 = 0, validity: ToolGrantValidity = .active) -> ToolScopedGrant {
        scopes.grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"), validity: validity, epoch: epoch)
    }
}
