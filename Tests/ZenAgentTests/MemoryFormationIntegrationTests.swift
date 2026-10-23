import Foundation
import Testing
@testable import ZenAgent

@Suite("Memory formation through real completed Runs")
struct MemoryFormationIntegrationTests {
    @Test(arguments: ["Please proofread this example biography:\nMy name is Alice",
                      "下面是客户的自我介绍：\n我的名字是 小明", "My name is Alice or Bob",
                      "My main project is Zen-Agent until tomorrow"])
    func thirdPartyAndQualifiedValuesDoNotReplaceCorrectUserFacts(source: String) async throws {
        let fixture = try MemoryPromptFixture.make()
        _ = try await fixture.send(text: "Remember that my name is Azusa")
        let original = try fixture.store.memories().first
        #expect(original?.content == "用户的名字是 Azusa。")
        _ = try await fixture.send(text: source)
        let items = try fixture.store.memories()
        #expect(items.count == 1)
        #expect(items.first?.revisionID == original?.revisionID)
        _ = try await fixture.send(text: "What is my name?")
        let requests = await fixture.ledger.requestsSnapshot()
        if let last = requests.last?.messages.last, case .user(let text) = last {
            #expect(text.contains("用户的名字是 Azusa。"))
            #expect(!text.contains("用户的名字是 Alice") && !text.contains("用户的名字是 小明"))
        } else { Issue.record("Missing actual request") }
    }
    @Test func completedRunFormsVisibleFactAndNextRunRetrievesIt() async throws {
        let fixture = try MemoryPromptFixture.make()
        #expect(try fixture.store.memorySettings().automaticEnabled)
        let runID = try await fixture.send(text: "我平时使用 Windows 开发")
        let items = try fixture.store.memories()
        #expect(items.count == 1)
        guard let item = items.first else { Issue.record("Completed current-user statement must form visible Memory"); return }
        #expect(item.content == "用户平时使用 Windows 开发。")
        #expect(item.origin == .automatic)
        #expect(item.sources.first?.conversationID == "memory-conversation")
        let run = try fixture.store.run(id: runID)
        #expect(item.sources.first?.messageID == run?.triggerMessageID)
        let runtime = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        runtime.formAfterCompletedRun(runID: runID)
        #expect(try fixture.store.memories().count == 1)
        _ = try await fixture.send(text: "帮我解决 Windows 开发问题")
        let requests = await fixture.ledger.requestsSnapshot()
        if case .user(let content) = requests[1].messages.last { #expect(content.contains(item.content)) }
        else { Issue.record("Missing user context") }
    }

    @Test func repeatedFactsMergeSourcesAndStableConflictUpdatesOnlyAutomaticRows() async throws {
        let fixture = try MemoryPromptFixture.make()
        _ = try await fixture.send(text: "我偏好中文回答")
        let initial = try fixture.store.memories()
        guard let original = initial.first else { Issue.record("Missing initial fact"); return }
        _ = try await fixture.send(text: "I prefer Chinese responses")
        let duplicate = try fixture.store.memories()
        #expect(duplicate.count == 1)
        #expect(duplicate.first?.sources.count == 2)
        #expect(duplicate.first?.revisionID == original.revisionID)
        _ = try await fixture.send(text: "记住：我偏好英文回答")
        let changed = try fixture.store.memories()
        guard let latest = changed.first else { Issue.record("Missing updated fact"); return }
        #expect(latest.content == "用户偏好使用英文回答。")
        #expect(latest.revisionID != original.revisionID)
        #expect(try fixture.store.memoryRevision(id: original.revisionID)?.content == original.content)
        let runtime = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        _ = try runtime.save(id: latest.id, expectedRevisionID: latest.revisionID, content: "用户手动决定的回答语言")
        _ = try await fixture.send(text: "我偏好中文回答")
        #expect(try fixture.store.memories().first?.content == "用户手动决定的回答语言")
    }

    @Test func disabledAndAssistantStatementsNeverFormMemory() async throws {
        let fixture = try MemoryPromptFixture.make(scripts: [.events([.textDelta("我偏好中文回答"), .finish(.stop)])])
        _ = try await fixture.send(text: "请介绍这个应用")
        #expect(try fixture.store.memories().isEmpty)
        let runtime = MemoryRuntime(store: fixture.store, credentials: fixture.credentials)
        try fixture.store.setMemoryAutomatic(false)
        _ = try await fixture.send(text: "我偏好中文回答")
        #expect(try fixture.store.memories().isEmpty)
        try fixture.store.setMemoryAutomatic(true)
        try runtime.setEnabled(false)
        _ = try await fixture.send(text: "我偏好中文回答")
        #expect(try fixture.store.memories().isEmpty)
    }

    @Test func credentialSourceAndFailedRunsNeverFormFactsOrChangeTheRunOutcome() async throws {
        let fixture = try MemoryPromptFixture.make()
        let runID = try await fixture.send(text: "记住：我的主要项目是 memory-fixture-private-value")
        #expect(try fixture.store.memories().isEmpty)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        let failed = try MemoryPromptFixture.make(scripts: [.failure(prefix: [])])
        let failedID = try await failed.send(text: "我偏好中文回答")
        #expect(try failed.store.run(id: failedID)?.state == .failed)
        #expect(try failed.store.memories().isEmpty)
    }

    @Test func enablingAutomaticFormationDoesNotBackfillACompletedOldStatement() async throws {
        let fixture = try MemoryPromptFixture.make()
        try fixture.store.setMemoryAutomatic(false)
        let oldRunID = try await fixture.send(text: "我偏好中文回答")
        try fixture.store.setMemoryAutomatic(true)
        MemoryRuntime(store: fixture.store, credentials: fixture.credentials).formAfterCompletedRun(runID: oldRunID)
        #expect(try fixture.store.memories().isEmpty)
        _ = try await fixture.send(text: "我偏好中文回答")
        #expect(try fixture.store.memories().count == 1)
    }
}
