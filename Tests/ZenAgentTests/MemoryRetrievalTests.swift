import Foundation
import Testing
@testable import ZenAgent

@Suite("Memory bounded local retrieval")
struct MemoryRetrievalTests {
    @Test("Latin and Chinese terms select relevant active facts without dumping unrelated records")
    func relevance() {
        let records = [item("windows", "I develop on Windows using Swift"), item("mac", "I use macOS"),
            item("chinese", "我偏好中文回答"), item("old", "Windows", archived: true)]
        #expect(MemoryRetriever.select(query: "Windows Swift help", records: records).map(\.id) == ["windows"])
        #expect(MemoryRetriever.select(query: "请用中文回答", records: records).map(\.id) == ["chinese"])
        #expect(MemoryRetriever.select(query: "gardening flowers", records: records).isEmpty)
        #expect(MemoryRetriever.select(query: " \n", records: records).isEmpty)
    }

    @Test("engineering caps apply to exact UTF8 boundaries and maximum record count")
    func bounds() {
        let many = (0..<10).map { item(String($0), "Windows " + String(repeating: "x", count: 1_016)) }
        let selected = MemoryRetriever.select(query: "Windows", records: many)
        #expect(selected.count == 4)
        #expect(selected.reduce(0) { $0 + $1.content.utf8.count } == 4_096)
        let short = (0..<10).map { item(String($0), "Windows \($0)") }
        #expect(MemoryRetriever.select(query: "Windows", records: short).count == 6)
        #expect(MemoryRetriever.select(query: "Windows", records: [item("big", "Windows " + String(repeating: "中", count: 400))]).isEmpty)
    }

    private func item(_ id: String, _ content: String, archived: Bool = false) -> MemoryItem {
        MemoryItem(id: id, revisionID: id + "-v", content: content, origin: .manual, factKey: nil,
            archived: archived, createdAt: .distantPast, updatedAt: .distantPast, sources: [])
    }
}
