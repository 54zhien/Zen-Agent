import Foundation
import Testing
@testable import ZenAgent

@Suite("Settings model-menu preferences")
@MainActor
struct SettingsModelMenuTests {
    @Test("menu hiding and order persist per instance without changing canonical capabilities")
    func preferencesKeepTheirInstanceScope() throws {
        let suite = "ZenAgentTests.SettingsMenus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ProviderInstanceID(rawValue: "menu-first")
        let second = ProviderInstanceID(rawValue: "menu-second")
        let a = ModelID(rawValue: "a")
        let b = ModelID(rawValue: "b")
        let canonical = [descriptor(a, in: first), descriptor(b, in: first)]
        let other = [descriptor(a, in: second), descriptor(b, in: second)]
        let preferences = ModelMenuPreferences(defaults: defaults)
        preferences.setOrder([b, a], for: first)
        preferences.setHidden(true, modelID: b, instanceID: first)
        #expect(preferences.orderedModels(canonical).map(\.id) == [b, a])
        #expect(preferences.visibleModels(canonical).map(\.id) == [a])
        #expect(preferences.visibleModels(other) == other)
        #expect(canonical[1].capabilities == [.text, .streaming, .reasoning])

        let restored = ModelMenuPreferences(defaults: defaults)
        #expect(restored.orderedModels(canonical).map(\.id) == [b, a])
        #expect(restored.visibleModels(canonical).map(\.id) == [a])
        #expect(restored.visibleModels(other) == other)
        let c = ModelID(rawValue: "new-provider-model")
        #expect(restored.visibleModels(canonical + [descriptor(c, in: first)]).map(\.id) == [a, c])
    }

    private func descriptor(_ id: ModelID, in instance: ProviderInstanceID) -> ModelDescriptor {
        ModelDescriptor(id: id, providerInstanceID: instance, displayName: id.rawValue,
            capabilities: [.text, .streaming, .reasoning])
    }
}
