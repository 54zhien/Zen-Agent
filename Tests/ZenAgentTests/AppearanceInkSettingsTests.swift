import Foundation
import Testing
@testable import ZenAgent

@Suite("Persisted Ink appearance", .serialized)
@MainActor
struct AppearanceInkSettingsTests {
    @Test("a fresh preference owner reloads the actual Ink controls")
    func controlsPersistAcrossOwners() {
        let name = "ZenAgent.InkAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppearanceSettings(defaults: defaults)
        first.inkEnabled = false
        first.inkIntensity = 0.7
        let restored = AppearanceSettings(defaults: defaults)
        #expect(!restored.inkEnabled && restored.inkIntensity == 0.7)
        restored.inkEnabled = true
        #expect(AppearanceSettings(defaults: defaults).inkEnabled)
    }

    @Test("invalid stored and edited intensity never reaches native rendering")
    func corruptedPreferencesAreFiniteAndBounded() {
        let name = "ZenAgent.InkAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for raw in [Double.nan, Double.infinity, -Double.infinity, -100, 100] {
            defaults.set(raw, forKey: "zen.appSpaceInk.intensity.v1")
            let owner = AppearanceSettings(defaults: defaults)
            #expect(owner.inkIntensity.isFinite && (0...1).contains(owner.inkIntensity))
            owner.inkIntensity = raw
            #expect(owner.inkIntensity.isFinite && (0...1).contains(owner.inkIntensity))
            let reloaded = AppearanceSettings(defaults: defaults)
            #expect(reloaded.inkIntensity.isFinite && (0...1).contains(reloaded.inkIntensity))
        }
    }
}
