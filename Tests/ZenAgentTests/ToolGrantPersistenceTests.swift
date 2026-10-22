import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("S6-03 scoped grant persistence")
struct ToolGrantPersistenceTests {
    @Test func exactScopesAndApprovalWitnessSurviveReopen() throws {
        let url = try Fixtures.scratchPath(name: "tool-grants.sqlite")
        defer { Fixtures.cleanUp(url) }
        let expected = GrantStorageFixture.grant()
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try GrantStorageFixture.seed(store)
            #expect(try store.issueToolGrant(id: "g", grant: expected, expectedPolicy: GrantStorageFixture.policy(store)))
        }
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try store.toolGrant(id: "g") == expected)
        #expect(try store.toolGrants(subject: .parentConversation("other")).isEmpty)
        let saved = try #require(store.toolGrant(id: "g"))
        #expect(!ToolGrantScopeMatcher.matches(grant: saved, call: GrantStorageFixture.context(version: "v2")))
        #expect(!ToolGrantScopeMatcher.matches(grant: saved, call: GrantStorageFixture.context(endpoint: "other-endpoint")))
    }

    @Test func tighteningThenWideningCannotRestoreGrantOrStaleIssuance() throws {
        let store = try GrantStorageFixture.store()
        let before = try GrantStorageFixture.policy(store)
        try #require(store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(), expectedPolicy: before))
        try store.setToolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "r1", mode: .deny)
        try store.setToolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "r1", mode: .alwaysAllow)
        #expect(try store.toolGrant(id: "g")?.validity == .revoked)
        #expect(try !store.issueToolGrant(id: "stale", grant: GrantStorageFixture.grant(), expectedPolicy: before))
        #expect(try !store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(epoch: 1), expectedPolicy: GrantStorageFixture.policy(store)))
    }

    @Test func explicitRevocationCannotBeOverwrittenByDuplicateApproval() throws {
        let store = try GrantStorageFixture.store()
        let policy = try GrantStorageFixture.policy(store)
        try #require(store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(), expectedPolicy: policy))
        #expect(try store.revokeToolGrant(id: "g"))
        #expect(try !store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(), expectedPolicy: policy))
        #expect(try store.toolGrant(id: "g")?.validity == .revoked)
    }

    @Test func originalCallTerminalConsumesOnceAndOriginalRunEndRevokesRunSubject() throws {
        let store = try GrantStorageFixture.store()
        let once = GrantStorageFixture.grant(subject: .run("r"), once: true)
        try #require(store.issueToolGrant(id: "once", grant: once, expectedPolicy: GrantStorageFixture.policy(store)))
        try #require(store.issueToolGrant(id: "run", grant: GrantStorageFixture.grant(subject: .run("r")), expectedPolicy: GrantStorageFixture.policy(store)))
        try store.settleToolCallForCancellation(id: "call")
        #expect(try store.toolGrant(id: "once")?.validity == .consumed)
        try store.finishRun(id: "r", state: .cancelled, endReason: .cancelledByUser)
        #expect(try store.toolGrant(id: "run")?.validity == .revoked)
        #expect(try !store.issueToolGrant(id: "late", grant: once, expectedPolicy: GrantStorageFixture.policy(store)))
    }

    @Test func parentGrantSurvivesRunButDeletionUndoNeverRevivesIt() throws {
        let store = try GrantStorageFixture.store()
        try #require(store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(), expectedPolicy: GrantStorageFixture.policy(store)))
        try store.finishRun(id: "r", state: .cancelled, endReason: .cancelledByUser)
        #expect(try store.toolGrant(id: "g")?.validity == .active)
        try store.beginDeletion(conversationID: "c")
        try store.undoDeletion(conversationID: "c")
        #expect(try store.toolGrant(id: "g")?.validity == .revoked)
    }

    @Test func invalidScopesWrongSubjectAndUnknownOriginDoNotMintAuthority() throws {
        let store = try GrantStorageFixture.store()
        let policy = try GrantStorageFixture.policy(store)
        #expect(try !store.issueToolGrant(id: "other", grant: GrantStorageFixture.grant(subject: .parentConversation("other")), expectedPolicy: policy))
        #expect(try !store.issueToolGrant(id: "run", grant: GrantStorageFixture.grant(subject: .run("other")), expectedPolicy: policy))
        #expect(try !store.issueToolGrant(id: "blank", grant: GrantStorageFixture.grant(binding: " "), expectedPolicy: policy))
        #expect(try !store.issueToolGrant(id: "version", grant: GrantStorageFixture.grant(version: "v2"), expectedPolicy: policy))
    }

    @Test func corruptScopeNeverDecodesAsUnrestrictedAuthority() throws {
        let store = try GrantStorageFixture.store()
        try #require(store.issueToolGrant(id: "g", grant: GrantStorageFixture.grant(), expectedPolicy: GrantStorageFixture.policy(store)))
        try store.database.write { db in
            try db.execute(sql: "UPDATE toolScopedGrant SET resource = ? WHERE id = ?", arguments: ["{", "g"])
        }
        #expect(throws: (any Error).self) { try store.toolGrant(id: "g") }
        #expect(throws: (any Error).self) { try store.toolGrants(subject: .parentConversation("c")) }
    }

    @Test func tighteningAndApprovalSerializeWithoutStaleActiveGrant() async throws {
        let store = try GrantStorageFixture.store()
        let policy = try GrantStorageFixture.policy(store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try store.issueToolGrant(id: "race", grant: GrantStorageFixture.grant(), expectedPolicy: policy) }
            group.addTask { _ = try store.setToolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "r1", mode: .deny) }
            try await group.waitForAll()
        }
        #expect(try store.toolGrant(id: "race")?.validity != .active)
        #expect(try GrantStorageFixture.policy(store).mode == .deny)
    }
}

// Storage receives trusted opaque intent bindings, never reconstructs them from UI.
// S6-04 must prove the runtime's binding derivation and dispatch integration.
enum GrantStorageFixture {
    static func store() throws -> PersistenceStore {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try seed(store)
        return store
    }
    static func seed(_ store: PersistenceStore) throws {
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        let action = ToolPolicyActionMetadata(toolID: "tool", actionID: "read", descriptorRevision: "r1", risk: .low,
            allowsAutomaticApproval: true, allowsConversationGrant: true, resourceRequirement: .file, egressRequirement: .provider)
        let descriptor = ToolDescriptor(id: "tool", displayName: "Read", description: "Storage fixture", inputSchema: .object([:]),
            revision: "r1", sideEffect: .none, approvalRequirement: .notRequired, actions: [action])
        let intent = try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "read", normalizedArgumentsJSON: "{}",
            resource: .file(assetID: "file", versionID: "v1", contentIdentity: "digest"),
            destination: .provider(instanceID: "provider", endpointIdentity: "endpoint"))
        let encoded = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        try store.createToolCall(Fixtures.toolCall(id: "call", runID: "r", action: "tool", state: .waitingForApproval, intent: encoded))
    }
    static func policy(_ store: PersistenceStore) throws -> ToolPolicySnapshot {
        try store.toolPolicy(toolID: "tool", actionID: "read", descriptorRevision: "r1")
    }
    static func grant(subject: ToolGrantSubject = .parentConversation("c"), once: Bool = false,
                      epoch: UInt64 = 0, version: String = "v1", binding: String = "binding") -> ToolScopedGrant {
        ToolScopedGrant(kind: once ? .once(toolCallID: "call", agentRunID: "r", intentBinding: binding) : .conversation,
            subject: subject, toolID: "tool", actionID: "read", descriptorRevision: "r1",
            resource: .file(assetID: "file", versionID: version, contentIdentity: "digest"),
            destination: .provider(instanceID: "provider", endpointIdentity: "endpoint"), validity: .active,
            revocationEpoch: epoch, issuedFor: ToolGrantApprovalBinding(toolCallID: "call", agentRunID: "r", intentBinding: binding))
    }
    static func context(version: String = "v1", endpoint: String = "endpoint") -> ToolPolicyCallContext {
        ToolPolicyCallContext(toolCallID: "later", agentRunID: "later-run", subject: .parentConversation("c"),
            toolID: "tool", actionID: "read", descriptorRevision: "r1", intentBinding: "later-binding",
            resource: .file(assetID: "file", versionID: version, contentIdentity: "digest"),
            destination: .provider(instanceID: "provider", endpointIdentity: endpoint), authorizationIsAvailable: true, subjectIsAvailable: true)
    }
}
