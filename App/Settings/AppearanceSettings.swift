import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor
@Observable
final class AppearanceSettings {
    var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "zen.appearance.v1") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: "zen.appearance.v1") ?? "") ?? .system
    }
}

@MainActor
@Observable
final class ModelMenuPreferences {
    private struct Entry: Codable { var order: [String] = []; var hidden: Set<String> = [] }
    private var entries: [String: Entry]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "zen.modelMenu.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
    }

    func isHidden(_ modelID: ModelID, in instanceID: ProviderInstanceID) -> Bool {
        entries[instanceID.rawValue]?.hidden.contains(modelID.rawValue) == true
    }

    func setHidden(_ hidden: Bool, modelID: ModelID, instanceID: ProviderInstanceID) {
        var entry = entries[instanceID.rawValue] ?? Entry()
        if hidden { entry.hidden.insert(modelID.rawValue) } else { entry.hidden.remove(modelID.rawValue) }
        entries[instanceID.rawValue] = entry
        persist()
    }

    func setOrder(_ models: [ModelID], for instanceID: ProviderInstanceID) {
        var seen: Set<String> = []
        var entry = entries[instanceID.rawValue] ?? Entry()
        entry.order = models.map(\.rawValue).filter { seen.insert($0).inserted }
        entries[instanceID.rawValue] = entry
        persist()
    }

    func orderedModels(_ canonical: [ModelDescriptor]) -> [ModelDescriptor] {
        guard let instance = canonical.first?.providerInstanceID,
              canonical.allSatisfy({ $0.providerInstanceID == instance }) else { return canonical }
        let order = entries[instance.rawValue]?.order ?? []
        let ordered = order.compactMap { id in canonical.first { $0.id.rawValue == id } }
        return ordered + canonical.filter { !order.contains($0.id.rawValue) }
    }

    func visibleModels(_ canonical: [ModelDescriptor]) -> [ModelDescriptor] {
        orderedModels(canonical).filter { !isHidden($0.id, in: $0.providerInstanceID) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

private struct ModelMenuPreferencesKey: EnvironmentKey {
    static let defaultValue: ModelMenuPreferences? = nil
}
extension EnvironmentValues {
    var modelMenuPreferences: ModelMenuPreferences? {
        get { self[ModelMenuPreferencesKey.self] }
        set { self[ModelMenuPreferencesKey.self] = newValue }
    }
}
