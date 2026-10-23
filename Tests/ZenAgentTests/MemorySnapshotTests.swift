import Foundation
import Testing
@testable import ZenAgent

@Suite("Memory snapshot reference encoding")
struct MemorySnapshotTests {
    @Test("exact revision references round trip without copying content and old snapshots have no Memory")
    func roundTrip() throws {
        let references = [MemoryRevisionReference(memoryID: "memory", revisionID: "revision")]
        let prompt = PromptExecutionSnapshot(runtimeSafetyBaseline: "r", zenCore: "c", providerAdapterInstructions: "a", memoryReferences: references)
        let data = try JSONEncoder().encode(prompt)
        let decoded = try JSONDecoder().decode(PromptExecutionSnapshot.self, from: data)
        #expect(decoded.memoryReferences == references)
        let old = Data(#"{"runtimeSafetyBaseline":"r","zenCore":"c","providerAdapterInstructions":"a"}"#.utf8)
        let legacy = try JSONDecoder().decode(PromptExecutionSnapshot.self, from: old)
        #expect(legacy.memoryReferences.isEmpty)
    }

    @Test("malformed or duplicate Memory references fail closed")
    func malformed() throws {
        for references in [[MemoryRevisionReference(memoryID: "", revisionID: "v")],
            [MemoryRevisionReference(memoryID: "m", revisionID: "v"), MemoryRevisionReference(memoryID: "m", revisionID: "v")]] {
            let prompt = PromptExecutionSnapshot(runtimeSafetyBaseline: "r", zenCore: "c", providerAdapterInstructions: "a", memoryReferences: references)
            let data = try JSONEncoder().encode(prompt)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(PromptExecutionSnapshot.self, from: data) }
        }
    }
}
