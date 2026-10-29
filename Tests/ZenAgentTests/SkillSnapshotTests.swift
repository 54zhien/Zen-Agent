import Foundation
import Testing
@testable import ZenAgent

@Suite("Stage8 frozen Skill snapshot compatibility")
struct SkillSnapshotTests {
    private let reference = SkillActivationReference(skillID: "s", revisionID: "v", environmentReferences: [],
        environmentFingerprint: "env-v1:" + String(repeating: "0", count: 64))

    @Test("new snapshots require v3 and round trip content-free Skill identities")
    func roundTrip() throws {
        let snapshot = RunExecutionSnapshot(providerID: .deepSeek, providerAdapterRevision: "adapter",
            prompt: .init(runtimeSafetyBaseline: "r", zenCore: "c", providerAdapterInstructions: "a", skillReferences: [reference]),
            modelCapabilities: [.text], exposedTools: [], maxProviderSteps: 4)
        #expect(snapshot.formatVersion == 3)
        let encoded = try ExecutionSnapshotCodec.encode(snapshot)
        #expect(try ExecutionSnapshotCodec.decode(encoded).prompt.skillReferences == [reference])
    }

    @Test("legacy v1 remains readable only without Skill semantics; malformed new references fail closed")
    func legacyAndMalformed() throws {
        let snapshot = RunExecutionSnapshot(providerID: .deepSeek, providerAdapterRevision: "a",
            prompt: .init(runtimeSafetyBaseline: "r", zenCore: "c", providerAdapterInstructions: "a"),
            modelCapabilities: [.text], exposedTools: [], maxProviderSteps: 4)
        let encoded = try ExecutionSnapshotCodec.encode(snapshot)
        let decodedObject = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        var object = try #require(decodedObject as? [String: Any])
        object["formatVersion"] = 1
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(try ExecutionSnapshotCodec.decode(legacy).prompt.skillReferences.isEmpty)
        var prompt = try #require(object["prompt"] as? [String: Any])
        prompt["skillReferences"] = [["skillID": "s", "revisionID": "v", "environmentReferences": [], "environmentFingerprint": reference.environmentFingerprint]]
        object["prompt"] = prompt
        let invalidLegacy = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: RunExecutionSnapshot.FormatError.self) { try ExecutionSnapshotCodec.decode(invalidLegacy) }
        object["formatVersion"] = 2
        prompt["skillReferences"] = [["skillID": "", "revisionID": "v", "environmentReferences": [], "environmentFingerprint": "forged"]]
        object["prompt"] = prompt
        let malformed = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: RunExecutionSnapshot.FormatError.self) { try ExecutionSnapshotCodec.decode(malformed) }
    }
}
