import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Memory formation transactional fences")
struct MemoryFormationTransactionTests {
    @Test func clearAndToggleInvalidateAQueuedCandidateAndOldSources() async throws {
        let fixture = try MemoryPromptFixture.make()
        let runID = try await fixture.send(text: "我偏好中文回答")
        // Removing only the content-free receipt models a candidate captured but
        // not yet committed; normal production never removes these receipts.
        try fixture.store.database.write { try $0.execute(sql: "DELETE FROM memoryExtractionReceipt") }
        let prepared = try fixture.store.prepareMemoryFormation(runID: runID)
        let input = try #require(prepared)
        let candidates = MemoryCandidateExtractor.extract(input.text)
        try fixture.store.clearMemory()
        try fixture.store.commitMemoryCandidates(candidates, from: input)
        #expect(try fixture.store.memories().isEmpty)
        #expect(try fixture.store.prepareMemoryFormation(runID: runID) == nil)
        let newID = try await fixture.send(text: "我偏好中文回答")
        #expect(try fixture.store.memories().count == 1, "A fresh user assertion can form again after erasure")
        try fixture.store.database.write { try $0.execute(sql: "DELETE FROM memoryExtractionReceipt") }
        let newPrepared = try fixture.store.prepareMemoryFormation(runID: newID)
        let newInput = try #require(newPrepared)
        try fixture.store.clearMemory()
        try fixture.store.setMemoryAutomatic(false)
        try fixture.store.setMemoryAutomatic(true)
        try fixture.store.commitMemoryCandidates(candidates, from: newInput)
        #expect(try fixture.store.memories().isEmpty)
    }

    @Test func concurrentCompletionIsIdempotentAndReceiptsContainNoBody() async throws {
        let fixture = try MemoryPromptFixture.make()
        let runID = try await fixture.send(text: "记住：我的主要项目是 Zen-Agent")
        let runtime = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { runtime.formAfterCompletedRun(runID: runID) } }
        }
        #expect(try fixture.store.memories().count == 1)
        let columns = try fixture.store.database.read { try $0.columns(in: "memoryExtractionReceipt").map(\.name) }
        #expect(Set(columns) == Set(["messageID", "createdAt"]))
        let count = try fixture.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memoryExtractionReceipt") }
        #expect(count == 1)
    }
}
