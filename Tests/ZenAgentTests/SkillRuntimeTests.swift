import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 Skill definitions and manual preparation")
struct SkillRuntimeTests {
    private func fixture() throws -> (PersistenceStore, CredentialStore, SkillRuntime) {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        return (store, credentials, SkillRuntime(store: store, credentials: credentials,
            registry: try ToolRegistry(tools: [CalculatorTool()])))
    }
    @Test("built-ins are opt-in, immutable and copied only through explicit user save")
    func builtIns() async throws {
        let (_, _, runtime) = try fixture()
        let initial = try runtime.list()
        #expect(initial.count == 2)
        guard let calculator = initial.first(where: { $0.id == "zen.calculate" }) else { return }
        #expect(!calculator.enabled)
        #expect(try runtime.prepare(query: "请计算 8 * 7", selectedSkillIDs: []).isEmpty)
        let copy = try runtime.copyDefinition(id: calculator.id)
        #expect(try runtime.list().count == 2, "opening a copy must not save keystrokes")
        let created = try runtime.saveUser(definition: copy)
        #expect(created.source == .userCreated)
        #expect(!created.enabled)
        #expect(throws: SkillError.builtInReadOnly) {
            try runtime.saveUser(id: calculator.id, expectedRevisionID: calculator.revisionID, definition: copy)
        }
        try await runtime.setEnabled(id: calculator.id, enabled: true)
        let prepared = try runtime.prepare(query: "hello", selectedSkillIDs: [calculator.id])
        #expect(prepared.map { $0.reference.skillID } == [calculator.id])
    }
    @Test("ordinary user edits retain frozen instructions; stale edits and explicit erasure fail closed")
    func frozenEdits() async throws {
        let (_, _, runtime) = try fixture()
        let maybeFirst = try? runtime.saveUser(definition: .init(name: "Concise", summary: "", instructions: "Keep a concise response."))
        #expect(maybeFirst != nil)
        guard let first = maybeFirst else { return }
        try await runtime.setEnabled(id: first.id, enabled: true)
        let context = try runtime.prepare(query: "hello", selectedSkillIDs: [first.id])
        let second = try runtime.saveUser(id: first.id, expectedRevisionID: first.revisionID,
            definition: .init(name: "Concise", summary: "", instructions: "Replacement workflow."))
        #expect(second.revisionID != first.revisionID)
        #expect(try runtime.resolveFrozen(context.map(\.reference)).first?.instructions == "Keep a concise response.")
        #expect(throws: SkillError.editConflict) {
            try runtime.saveUser(id: first.id, expectedRevisionID: first.revisionID, definition: first.definition)
        }
        try await runtime.delete(id: first.id)
        #expect(throws: SkillError.erasedDependency) { try runtime.resolveFrozen(context.map(\.reference)) }
    }
    @Test("missing tool or unsupported MCP dependency blocks explicit activation without creating permissions")
    func dependencies() async throws {
        let (store, _, runtime) = try fixture()
        let maybeItem = try? runtime.saveUser(definition: .init(name: "Unavailable", summary: "", instructions: "Use requested data.", requiredTools: ["unknown-tool"], requiredMCPServers: ["future-server"]))
        #expect(maybeItem != nil)
        guard let item = maybeItem else { return }
        try await runtime.setEnabled(id: item.id, enabled: true)
        let current = try runtime.list().first(where: { $0.id == item.id })
        let status = try runtime.dependencyStatus(for: current ?? item)
        #expect(!status.isAvailable)
        #expect(throws: SkillError.missingDependency) { try runtime.prepare(query: "hello", selectedSkillIDs: [item.id]) }
        #expect(try store.toolGrantsForSettings().isEmpty)
    }
    @Test("known Environment secrets cannot become Skill instruction text")
    func secrets() throws {
        let (store, credentials, runtime) = try fixture()
        let env = EnvironmentRuntime(store: store, credentials: credentials)
        try env.saveSecret(key: "SERVICE_AUTH", value: SecretValue("fixture-skill-private"))
        #expect(throws: SkillError.unsafeContent) {
            try runtime.saveUser(definition: .init(name: "Unsafe", summary: "", instructions: "Use fixture-skill-private"))
        }
    }
}
