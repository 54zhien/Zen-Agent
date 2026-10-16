import Testing
@testable import ZenAgent

@Suite("Tool Policy aggregate identity equality")
struct ToolPolicyIdentityEqualityTests {
    private let composed = "identity/\u{e9}"
    private let decomposed = "identity/e\u{301}"

    @Test(arguments: ["subject", "tool", "action", "revision", "call", "run", "binding",
                      "target", "asset", "version", "content", "provider", "endpoint"])
    func callAndGrantEqualityPreserveOpaqueBytes(field: String) {
        let fixtures = ToolPolicyScopeTests()
        let first = fixtures.identityPair(field: field, callValue: composed, grantValue: composed)
        let copy = fixtures.identityPair(field: field, callValue: composed, grantValue: composed)
        let other = fixtures.identityPair(field: field, callValue: decomposed, grantValue: decomposed)
        #expect(first.0 == copy.0 && first.1 == copy.1)
        #expect(first.0 != other.0)
        #expect(first.1 != other.1)
    }

    @Test(arguments: ["call", "run", "binding"])
    func explicitApprovalWitnessPreservesOpaqueBytes(field: String) {
        func witness(_ value: String) -> ToolGrantApprovalBinding {
            .init(toolCallID: field == "call" ? value : "call",
                  agentRunID: field == "run" ? value : "run",
                  intentBinding: field == "binding" ? value : "binding")
        }
        #expect(witness(composed) == witness(composed))
        #expect(witness(composed) != witness(decomposed))
    }

    @Test(arguments: ["tool", "action", "revision"])
    func descriptorAndPolicyEqualityPreserveOpaqueBytes(field: String) {
        func policy(_ value: String) -> ToolPolicySnapshot {
            ToolPolicyEvaluatorTests().policy(tool: field == "tool" ? value : "files",
                action: field == "action" ? value : "read", revision: field == "revision" ? value : "r1")
        }
        func metadata(_ value: String) -> ToolPolicyActionMetadata {
            let identity = policy(value)
            return .init(toolID: identity.toolID, actionID: identity.actionID,
                descriptorRevision: identity.descriptorRevision, risk: .low,
                allowsAutomaticApproval: true, allowsConversationGrant: true,
                resourceRequirement: .notRequired, egressRequirement: .notRequired)
        }
        #expect(policy(composed) == policy(composed))
        #expect(metadata(composed) == metadata(composed))
        #expect(policy(composed) != policy(decomposed))
        #expect(metadata(composed) != metadata(decomposed))
    }

    @Test func frozenAndResolvedBindingsPreserveOpaqueBytes() {
        let fixture = ToolPolicyEvaluatorTests()
        let admission = ToolPolicyAdmission(disposition: .allowed, intentBinding: composed)
        #expect(admission == ToolPolicyAdmission(disposition: .allowed, intentBinding: composed))
        #expect(admission != ToolPolicyAdmission(disposition: .allowed, intentBinding: decomposed))
        #expect(fixture.input(resolvedBinding: composed) == fixture.input(resolvedBinding: composed))
        #expect(fixture.input(resolvedBinding: composed) != fixture.input(resolvedBinding: decomposed))
    }
}
