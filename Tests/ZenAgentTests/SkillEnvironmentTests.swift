import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 declared scoped Environment")
struct SkillEnvironmentTests {
    @Test("active Skill overrides Global, excludes siblings and pins ordinary edits")
    func scopeAndVersions() throws {
        let (environment, skills) = try fixture()
        let first = try skills.saveUser(definition: .init(name: "First", summary: "", instructions: "Use ${REGION}", environmentKeys: ["REGION"]))
        let sibling = try skills.saveUser(definition: .init(name: "Sibling", summary: "", instructions: "Use ${REGION}", environmentKeys: ["REGION"]))
        try environment.savePlain(key: "REGION", value: "global")
        let own = try environment.savePlain(scope: .skill(first.id), key: "REGION", value: "own")
        try environment.savePlain(scope: .skill(sibling.id), key: "REGION", value: "sibling")
        let binding = try environment.bind(skillID: first.id, declaredKeys: ["REGION"])
        #expect(binding.references == [own.reference])
        #expect(try environment.interpolate("Region ${REGION}", binding: binding, skillID: first.id, declaredKeys: ["REGION"]) == "Region own")
        try environment.savePlain(id: own.id, expectedRevisionID: own.revisionID, scope: own.scope, key: own.key, value: "new")
        #expect(try environment.interpolate("${REGION}", binding: binding, skillID: first.id, declaredKeys: ["REGION"]) == "own")
        #expect(throws: EnvironmentError.erasedDependency) {
            try environment.interpolate("${REGION}", binding: binding, skillID: sibling.id, declaredKeys: ["REGION"])
        }
    }

    @Test("only declared references resolve and expansion is bounded and cycle-safe")
    func references() throws {
        let (environment, skills) = try fixture()
        let item = try skills.saveUser(definition: .init(name: "References", summary: "", instructions: "Read config"))
        try environment.savePlain(key: "A", value: "${B}")
        try environment.savePlain(key: "B", value: "value")
        #expect(throws: EnvironmentError.missingReference) { try environment.bind(skillID: item.id, declaredKeys: ["A"]) }
        let valid = try environment.bind(skillID: item.id, declaredKeys: ["A", "B"])
        #expect(try environment.interpolate("${A}", binding: valid, skillID: item.id, declaredKeys: ["A", "B"]) == "value")
        let listed = try environment.list()
        let b = try #require(listed.first { $0.key == "B" })
        try environment.savePlain(id: b.id, expectedRevisionID: b.revisionID, key: "B", value: "${A}")
        #expect(throws: EnvironmentError.cycle) { try environment.bind(skillID: item.id, declaredKeys: ["A", "B"]) }
        #expect(throws: EnvironmentError.missingReference) { try environment.bind(skillID: item.id, declaredKeys: ["ABSENT"]) }
        #expect(throws: EnvironmentError.missingReference) {
            try environment.interpolate("${UNDECLARED}", binding: valid, skillID: item.id, declaredKeys: ["A", "B"])
        }
    }

    @Test("Secret never interpolates; trusted resolution requires frozen declared scope and live generation")
    func secretBoundary() async throws {
        let (environment, skills) = try fixture()
        let item = try skills.saveUser(definition: .init(name: "Secret", summary: "", instructions: "Use service"))
        let secret = try environment.saveSecret(key: "AUTH", value: SecretValue("fixture-scoped-secret"))
        let binding = try environment.bind(skillID: item.id, declaredKeys: ["AUTH"])
        #expect(!String(decoding: try JSONEncoder().encode(binding), as: UTF8.self).contains("fixture-scoped-secret"))
        #expect(throws: EnvironmentError.secretInterpolation) {
            try environment.interpolate("${AUTH}", binding: binding, skillID: item.id, declaredKeys: ["AUTH"])
        }
        #expect(try environment.resolveSecret(key: "AUTH", binding: binding, skillID: item.id, declaredKeys: ["AUTH"]).revealed == "fixture-scoped-secret")
        #expect(throws: EnvironmentError.erasedDependency) {
            try environment.resolveSecret(key: "AUTH", binding: .init(references: binding.references, fingerprint: "forged"), skillID: item.id, declaredKeys: ["AUTH"])
        }
        try await environment.delete(id: secret.id)
        #expect(throws: EnvironmentError.erasedDependency) {
            try environment.resolveSecret(key: "AUTH", binding: binding, skillID: item.id, declaredKeys: ["AUTH"])
        }
    }

    private func fixture() throws -> (EnvironmentRuntime, SkillRuntime) {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: InMemorySecretBackend(), metadataRepository: store)
        return (EnvironmentRuntime(store: store, credentials: credentials),
            SkillRuntime(store: store, credentials: credentials, registry: .empty))
    }
}
