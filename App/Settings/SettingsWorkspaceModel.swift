import Foundation
import Observation

struct SettingsProviderCatalog: Sendable, Identifiable {
    let instance: ProviderInstance
    let models: [ModelDescriptor]
    let credentialStatus: String
    var id: ProviderInstanceID { instance.id }
}

@MainActor
@Observable
final class SettingsWorkspaceModel {
    let appearance: AppearanceSettings
    let menus: ModelMenuPreferences
    let soul: SoulSettingsModel
    let storage: SettingsStorageModel?
    private(set) var catalog: [SettingsProviderCatalog] = []
    private(set) var defaultTarget: AppExecutionTarget?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isSelectingDefault = false
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let provider: any ModelProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onDefault: (AppExecutionTarget, Bool) -> Void
    @ObservationIgnored private let onProviderCommitted: @MainActor (ProviderInstanceID) async -> Void
    @ObservationIgnored private var active = true
    @ObservationIgnored private var selection: UInt64 = 0

    init(store: PersistenceStore, credentials: any CredentialStoring, provider: any ModelProvider,
         defaults: UserDefaults, appearance: AppearanceSettings, menus: ModelMenuPreferences,
         files: ManagedFileStore?,
         onProviderCommitted: @escaping @MainActor (ProviderInstanceID) async -> Void = { _ in },
         onDefault: @escaping (AppExecutionTarget, Bool) -> Void) {
        self.store = store; self.credentials = credentials; self.provider = provider
        self.defaults = defaults; self.appearance = appearance; self.menus = menus; self.onDefault = onDefault
        self.onProviderCommitted = onProviderCommitted
        soul = SoulSettingsModel(store: store)
        storage = files.map { SettingsStorageModel(store: store, files: $0) }
        if let instance = defaults.string(forKey: AppShellModel.defaultInstanceIDKey),
           let model = defaults.string(forKey: AppShellModel.defaultModelIDKey) {
            defaultTarget = AppExecutionTarget(providerInstanceID: .init(rawValue: instance), modelID: .init(rawValue: model))
        }
    }

    func load() async {
        guard active, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let store = store, credentials = credentials, provider = provider
        do {
            let result = try await Task.detached {
                try store.providerInstances().map { instance in
                    let status: String
                    if let reference = instance.credentialReference {
                        do {
                            let metadata = try credentials.metadata(for: reference)
                            status = metadata?.status == .active ? "凭据记录已保存，未联网验证" : "需要重新配置凭据"
                        } catch { status = "凭据状态暂不可读" }
                    } else { status = "尚未配置凭据" }
                    return SettingsProviderCatalog(instance: instance,
                        models: provider.knownModels(for: instance), credentialStatus: status)
                }
            }.value
            guard active, !Task.isCancelled else { return }
            catalog = result; errorMessage = nil
        } catch { if active { errorMessage = "账户和模型读取失败，请重试。" } }
    }

    func setDefault(providerInstanceID: ProviderInstanceID, modelID: ModelID) async -> Bool {
        guard active else { return false }
        selection &+= 1
        let request = selection
        isSelectingDefault = true; errorMessage = nil
        defer { if request == selection { isSelectingDefault = false } }
        let store = store, credentials = credentials, provider = provider
        do {
            _ = try await Task.detached {
                try AppAssembly.validateTarget(providerInstanceID: providerInstanceID, modelID: modelID,
                    store: store, provider: provider, credentials: credentials)
            }.value
            guard active, request == selection, !Task.isCancelled else { return false }
            let target = AppExecutionTarget(providerInstanceID: providerInstanceID, modelID: modelID)
            defaults.set(providerInstanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
            defaults.set(modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
            defaultTarget = target
            onDefault(target, false)
            return true
        } catch {
            if active, request == selection { errorMessage = "该模型暂不能作为默认，请检查账户和凭据。" }
            return false
        }
    }

    func makeProviderSetup() -> ProviderSetupModel? {
        guard active else { return nil }
        return ProviderSetupModel(store: store, credentials: credentials, provider: provider, userDefaults: defaults,
            onTargetSaved: { [weak self, onDefault] target in
                self?.defaultTarget = target
                onDefault(target, self?.active == true)
            })
    }

    func accountEditor(for instance: ProviderInstance) -> ProviderAccountSettingsModel {
        // Publication remains meaningful after this Settings presentation closes.
        ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            onCommitted: onProviderCommitted)
    }

    func invalidate() {
        active = false; selection &+= 1; isSelectingDefault = false
        soul.invalidate(); storage?.invalidate()
    }
}
