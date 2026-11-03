import Foundation
import Testing

@testable import ZenAgent

@Suite("Thinking effort request contract")
struct ThinkingEffortTests {
    @Test("model-declared effort choices are ordered and selection clears on model change")
    func modelSpecificLevels() {
        let instanceID = ProviderInstanceID(rawValue: "effort-instance")
        let three = ModelDescriptor(id: ModelID(rawValue: "three"), providerInstanceID: instanceID,
            displayName: "Three", capabilities: [.text, .reasoning],
            thinkingEfforts: [.low, .high, .max], defaultThinkingEffort: .high)
        let four = ModelDescriptor(id: ModelID(rawValue: "four"), providerInstanceID: instanceID,
            displayName: "Four", capabilities: [.text, .reasoning],
            thinkingEfforts: [.low, .medium, .high, .xhigh], defaultThinkingEffort: .medium)

        #expect(three.supportedThinkingEfforts == [.low, .high, .max])
        #expect(four.supportedThinkingEfforts == [.low, .medium, .high, .xhigh])
        var configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID, modelID: three.id, thinkingEffort: .max)
        configuration.selectModel(four)
        #expect(configuration.modelID == four.id)
        #expect(configuration.thinkingEffort == nil)
    }

    @Test("selected effort freezes into the Parent request seed and summary")
    func selectedEffortIsFrozen() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let provider = FakeProvider(instanceID: fixture.instance.id, capabilities: [.text, .streaming],
            thinkingEfforts: [.low, .high],
            scriptedEvents: [.textDelta("answer"), .finish(.stop)])
        let runtime = ConversationRuntime(store: fixture.store, provider: provider, credentials: fixture.credentials)
        var command = I05RuntimeTestFixtures.command()
        command.thinkingEffort = .low

        let runID = try await runtime.send(command)

        #expect(try fixture.store.run(id: runID)?.requestConfigSeed.thinkingEffort == .low)
        let summary = try #require(fixture.store.conversationSummaryWindow(ids: [command.conversationID]).first)
        #expect(summary.thinkingEffort == .low)
    }
    @Test("v1 seeds remain readable and v2 effort seeds upgrade when output limits are frozen")
    func legacySeedsUpgradeWithoutLosingFrozenFields() throws {
        let seed = Fixtures.run(id: "effort-legacy").requestConfigSeed
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
        json["formatVersion"] = 1
        json.removeValue(forKey: "thinkingEffort")
        json.removeValue(forKey: "maxOutputTokens")

        let legacy = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.thinkingEffort == nil)
        #expect(legacy.maxOutputTokens == nil)
        #expect(legacy.anthropicWorkspaceID == nil)
        var selected = legacy
        selected.thinkingEffort = .high
        #expect(selected.formatVersion == 2)
        #expect(try JSONDecoder().decode(RequestConfigSeed.self, from: JSONEncoder().encode(selected)) == selected)

        var v2JSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any])
        v2JSON.removeValue(forKey: "maxOutputTokens")
        let v2 = try JSONDecoder().decode(RequestConfigSeed.self, from: JSONSerialization.data(withJSONObject: v2JSON))
        #expect(v2.formatVersion == 2)
        #expect(v2.thinkingEffort == .high)
        #expect(v2.maxOutputTokens == nil)
        #expect(v2.anthropicWorkspaceID == nil)

        var frozen = v2
        frozen.maxOutputTokens = 4096
        #expect(frozen.formatVersion == 3)
        #expect(frozen.anthropicWorkspaceID == nil)
        #expect(try JSONDecoder().decode(RequestConfigSeed.self, from: JSONEncoder().encode(frozen)) == frozen)

        frozen.anthropicWorkspaceID = "wrkspc_frozen"
        #expect(frozen.formatVersion == 4)
        #expect(try JSONDecoder().decode(RequestConfigSeed.self, from: JSONEncoder().encode(frozen)) == frozen)
    }
}
