import Foundation
import Testing

@testable import ZenAgent

@Suite("Thinking effort request contract")
struct ThinkingEffortTests {
    @Test("three and four level models expose only declared controls")
    func modelSpecificLevels() {
        let instance = ProviderInstanceID(rawValue: "effort-instance")
        let three = ModelDescriptor(id: ModelID(rawValue: "three"), providerInstanceID: instance,
            displayName: "Three", capabilities: [.text, .reasoning],
            thinkingEfforts: [.low, .high, .max], defaultThinkingEffort: .high)
        let four = ModelDescriptor(id: ModelID(rawValue: "four"), providerInstanceID: instance,
            displayName: "Four", capabilities: [.text, .reasoning],
            thinkingEfforts: [.low, .medium, .high, .xhigh], defaultThinkingEffort: .medium)
        #expect(three.supportedThinkingEfforts == [.low, .high, .max])
        #expect(four.supportedThinkingEfforts == [.low, .medium, .high, .xhigh])
        var configuration = ConversationComposerConfiguration(providerInstanceID: instance,
            modelID: three.id, thinkingEffort: .max)
        configuration.selectModel(four)
        #expect(configuration.modelID == four.id)
        #expect(configuration.thinkingEffort == nil)
        let reasoningOnly = ModelDescriptor(id: three.id, providerInstanceID: instance,
            displayName: "Reasoning without control", capabilities: [.text, .reasoning])
        #expect(reasoningOnly.supportedThinkingEfforts.isEmpty)
    }

    @Test("effort control does not require visible reasoning output")
    func hiddenReasoningCanStillHaveEffortControl() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(instanceID: f.instance.id, capabilities: [.text, .streaming],
            thinkingEfforts: [.low, .high], scriptedEvents: [.textDelta("answer"), .finish(.stop)])
        #expect(provider.descriptor(for: I05RuntimeTestFixtures.modelID, in: f.instance)?.supportedThinkingEfforts == [.low, .high])
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials)
        var command = I05RuntimeTestFixtures.command()
        command.thinkingEffort = .low
        let runID = try await runtime.send(command)
        #expect(try f.store.run(id: runID)?.requestConfigSeed.thinkingEffort == .low)
    }

    @Test("unsupported effort fails before any user turn is committed")
    func unsupportedEffortCannotCommit() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(instanceID: f.instance.id, thinkingEfforts: [.low, .high, .max], scriptedEvents: [.textDelta("answer"), .finish(.stop)])
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials)
        var command = I05RuntimeTestFixtures.command()
        command.thinkingEffort = .ultra
        await #expect(throws: ProviderError.self) { _ = try await runtime.start(command) }
        #expect(try f.store.messages(inConversation: command.conversationID).isEmpty)
        #expect(try f.store.runs(inConversation: command.conversationID).isEmpty)
    }

    @Test("effort freezes durably and participates in submission identity")
    func frozenEffortAndSubmissionIdentity() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(instanceID: f.instance.id, thinkingEfforts: [.low, .high, .max], scriptedEvents: [.textDelta("answer"), .finish(.stop)])
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials)
        var command = I05RuntimeTestFixtures.command()
        command.thinkingEffort = .high
        let runID = try await runtime.send(command)
        #expect(try f.store.run(id: runID)?.requestConfigSeed.thinkingEffort == .high)
        let summary = try #require(f.store.conversationSummaryWindow(ids: [command.conversationID]).first)
        #expect(summary.thinkingEffort == .high)
        command.thinkingEffort = .low
        await #expect(throws: ConversationRuntimeError.submissionIDPayloadConflict(command.submissionID)) {
            _ = try await runtime.start(command)
        }
        #expect(try f.store.run(id: runID)?.requestConfigSeed.thinkingEffort == .high)
    }

    @Test("default effort preserves the pre-effort submission digest")
    func nilEffortKeepsLegacyDigest() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let runtime = ConversationRuntime(store: f.store, provider: FakeProvider(instanceID: f.instance.id, scriptedEvents: [.textDelta("answer"), .finish(.stop)]),
            credentials: f.credentials)
        let runID = try await runtime.send(I05RuntimeTestFixtures.command())
        #expect(try f.store.run(id: runID)?.submissionDigest == "7b7470e99c04a841c1be7a1759f48521214d38f0d81f481abf22a03e8df16549")
    }

    @Test("v1 requests remain readable without a synthetic effort")
    func legacySeedAndVersionedEffort() throws {
        let seed = Fixtures.run(id: "seed-fixture").requestConfigSeed
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
        json["formatVersion"] = 1
        json.removeValue(forKey: "thinkingEffort")
        let old = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.thinkingEffort == nil)
        var selected = old
        selected.thinkingEffort = .high
        #expect(selected.formatVersion == 2)
        let restored = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONEncoder().encode(selected))
        #expect(restored == selected)
        json["formatVersion"] = 2
        #expect(throws: RequestConfigSeed.FormatError.malformedCurrentVersion(2)) {
            _ = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONSerialization.data(withJSONObject: json))
        }
        json["thinkingEffort"] = "unsupported-future-value"
        #expect(throws: RequestConfigSeed.FormatError.malformedCurrentVersion(2)) {
            _ = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
