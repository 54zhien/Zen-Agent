import Testing

@testable import ZenAgent

@Suite("Tool Policy exact scope and subject")
struct ToolPolicyScopeTests {
    @Test func sameExactScopeMatches() {
        #expect(ToolGrantScopeMatcher.matches(grant: grant(), call: call()))
    }

    @Test(arguments: [ToolResourceScope.missing, .target(""),
                      .file(assetID: "asset", versionID: "", contentIdentity: "digest"),
                      .file(assetID: "asset", versionID: "version", contentIdentity: "")])
    func missingScopeIsNotWildcard(resource: ToolResourceScope) {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(resource: resource), call: call(resource: resource)))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(resource: resource)))
    }

    @Test func differentResourceDoesNotMatch() {
        // Display names never enter identity: distinct assets remain distinct.
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(resource: .file(assetID: "other", versionID: "version", contentIdentity: "digest"))))
    }

    @Test func differentFileVersionDoesNotMatch() {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(resource: .file(assetID: "asset", versionID: "v2", contentIdentity: "digest"))))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(resource: .file(assetID: "asset", versionID: "version", contentIdentity: "changed"))))
    }

    @Test(arguments: [ToolDestinationScope.provider(instanceID: "provider", endpointIdentity: "other-endpoint"),
                      .provider(instanceID: "other-provider", endpointIdentity: "endpoint"),
                      .missing, .provider(instanceID: "", endpointIdentity: "endpoint"),
                      .provider(instanceID: "provider", endpointIdentity: "")])
    func differentDestinationDoesNotMatch(destination: ToolDestinationScope) {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(destination: destination)))
        if !destination.isValid {
            #expect(!ToolGrantScopeMatcher.matches(grant: grant(destination: destination), call: call(destination: destination)))
        }
    }

    @Test(arguments: [ToolGrantSubject.parentConversation("other"), .run("run"), .parentConversation("")])
    func differentSubjectDoesNotMatch(subject: ToolGrantSubject) {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(subject: subject)))
    }

    @Test func differentActionDoesNotMatch() {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(actionID: "delete")))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(toolID: "other-tool")))
    }

    @Test func descriptorRevisionChangeInvalidatesGrant() {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(revision: "r2")))
    }

    @Test func scopeLessOnlyMatchesExplicitNoRequirements() {
        let scopedGrant = grant(resource: .notRequired, destination: .notRequired)
        #expect(ToolGrantScopeMatcher.matches(grant: scopedGrant, call: call(resource: .notRequired, destination: .notRequired)))
        #expect(!ToolGrantScopeMatcher.matches(grant: scopedGrant, call: call()))
        #expect(!ToolGrantScopeMatcher.matches(grant: scopedGrant, call: call(resource: .missing, destination: .notRequired)))
        #expect(!ToolGrantScopeMatcher.matches(grant: scopedGrant, call: call(resource: .notRequired, destination: .missing)))
    }

    @Test func exactTargetScopeMatches() {
        #expect(ToolGrantScopeMatcher.matches(grant: grant(resource: .target("target")), call: call(resource: .target("target"))))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(resource: .target("target")), call: call(resource: .target("other"))))
    }

    @Test func onceMatchesOnlyItsFrozenCall() {
        let once = grant(kind: .once(toolCallID: "call", agentRunID: "run", intentBinding: "intent"))
        #expect(ToolGrantScopeMatcher.matches(grant: once, call: call()))
        #expect(!ToolGrantScopeMatcher.matches(grant: once, call: call(callID: "other")))
        #expect(!ToolGrantScopeMatcher.matches(grant: once, call: call(runID: "other")))
        #expect(!ToolGrantScopeMatcher.matches(grant: once, call: call(binding: "changed")))
    }

    @Test func conversationGrantCanMatchLaterCallInSameExactScope() {
        #expect(ToolGrantScopeMatcher.matches(grant: grant(), call: call(callID: "next", runID: "next-run", binding: "next-intent")))
    }

    @Test(arguments: [ToolGrantValidity.revoked, .consumed])
    func inactiveGrantCannotMatch(validity: ToolGrantValidity) {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(validity: validity), call: call()))
    }

    @Test func malformedCallIdentityCannotMatch() {
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(callID: "")))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(runID: "")))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(binding: "")))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(), call: call(revision: "")))
        #expect(!ToolGrantScopeMatcher.matches(grant: grant(subject: .run("different")), call: call(subject: .run("different"))))
    }

    func call(callID: String = "call", runID: String = "run", subject: ToolGrantSubject = .parentConversation("conversation"),
              toolID: String = "files", actionID: String = "read", revision: String = "r1", binding: String = "intent",
              resource: ToolResourceScope = .file(assetID: "asset", versionID: "version", contentIdentity: "digest"),
              destination: ToolDestinationScope = .provider(instanceID: "provider", endpointIdentity: "endpoint")) -> ToolPolicyCallContext {
        ToolPolicyCallContext(toolCallID: callID, agentRunID: runID, subject: subject, toolID: toolID,
                              actionID: actionID, descriptorRevision: revision, intentBinding: binding,
                              resource: resource, destination: destination)
    }

    func grant(kind: ToolGrantKind = .conversation, subject: ToolGrantSubject = .parentConversation("conversation"),
               toolID: String = "files", actionID: String = "read", revision: String = "r1",
               resource: ToolResourceScope = .file(assetID: "asset", versionID: "version", contentIdentity: "digest"),
               destination: ToolDestinationScope = .provider(instanceID: "provider", endpointIdentity: "endpoint"),
               validity: ToolGrantValidity = .active) -> ToolScopedGrant {
        ToolScopedGrant(kind: kind, subject: subject, toolID: toolID, actionID: actionID, descriptorRevision: revision,
                        resource: resource, destination: destination, validity: validity)
    }
}
