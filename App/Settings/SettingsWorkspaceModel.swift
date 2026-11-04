import Foundation
import Observation

struct SettingsProviderCatalog: Sendable, Identifiable {
    let instance: ProviderInstance
    let models: [ModelDescriptor]
    let credentialStatus: String
    let credentialIsActive: Bool
    let resolvedEndpointDisplaysByModelID: [ModelID: String]
    var id: ProviderInstanceID { instance.id }

    init(instance: ProviderInstance, models: [ModelDescriptor], credentialStatus: String,
         credentialIsActive: Bool, resolvedEndpointDisplaysByModelID: [ModelID: String] = [:]) {
        self.instance = instance
        self.models = models
        self.credentialStatus = credentialStatus
        self.credentialIsActive = credentialIsActive
        self.resolvedEndpointDisplaysByModelID = resolvedEndpointDisplaysByModelID
    }
}

/// The UI gets only display-safe URL components; the frozen request seed keeps the full destination.
private func sanitizedEndpointDisplay(_ endpoint: URL) -> String? {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
          components.scheme != nil, components.host != nil else { return nil }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string
}

@MainActor
@Observable
final class SettingsWorkspaceModel {
    let appearance: AppearanceSettings
    let menus: ModelMenuPreferences
    let soul: SoulSettingsModel
    let memory: MemorySettingsModel
    let skills: SkillSettingsModel
    let environment: EnvironmentSettingsModel
    let tools: ToolSettingsModel
    let mcp: MCPSettingsModel
    let subagents: SubagentSettingsModel
    let vectorSearch: VectorSearchSettingsModel
    let storage: SettingsStorageModel?
    private(set) var catalog: [SettingsProviderCatalog] = []
    private(set) var hasLoadedProviderCatalog = false
    private(set) var defaultTarget: AppExecutionTarget?
    private(set) var imageInputTarget: AppExecutionTarget?
    private(set) var isSelectingImageInputModel = false
    private(set) var imageInputSelectionErrorMessage: String?
    var errorMessage: String? { configurationErrorMessage ?? catalogLoadErrorMessage ?? defaultSelectionErrorMessage }
    var imageInputCatalogStatusMessage: String? {
        if isLoading { return "正在读取账户和模型目录。" }
        if catalogLoadErrorMessage != nil {
            return "账户和模型目录读取失败，暂时无法判断是否有支持图像输入的模型。"
        }
        if !hasLoadedProviderCatalog { return "账户和模型目录尚未读取。" }
        return nil
    }
    var canRetryImageInputCatalog: Bool { catalogLoadErrorMessage != nil }
    private(set) var configurationErrorMessage: String?
    private(set) var configurationStatusMessage: String?
    private var catalogLoadErrorMessage: String?
    private var defaultSelectionErrorMessage: String?
    private(set) var isLoading = false
    private(set) var isSelectingDefault = false
    private(set) var isConfiguringConversation = false
    var isConfigureMode: Bool { onConfigure != nil }
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let providerRegistry: ModelProviderRegistry
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onDefault: (AppExecutionTarget, Bool) -> Void
    @ObservationIgnored private let onConfigure: (@MainActor (AppExecutionTarget) throws -> Bool)?
    @ObservationIgnored private let onProviderCommitted: @MainActor (ProviderInstanceID) async -> Void
    @ObservationIgnored private var active = true
    @ObservationIgnored private var selection: UInt64 = 0
    @ObservationIgnored private var configurationSelection: UInt64 = 0
    @ObservationIgnored private var imageInputSelection: UInt64 = 0

    init(store: PersistenceStore, credentials: any CredentialStoring, provider: any ModelProvider,
         defaults: UserDefaults, appearance: AppearanceSettings, menus: ModelMenuPreferences,
         files: ManagedFileStore?,
         mcpRegistry: MCPServerRegistry,
         mcpRuntime: MCPServerRuntime,
         toolRegistry: ToolRegistry = .empty,
         toolSafetyCap: ToolPolicySafetyCap = .unrestricted,
         onStopExtensionRuns: EnvironmentRuntime.StopRuns? = nil,
         onConfigure: (@MainActor (AppExecutionTarget) throws -> Bool)? = nil,
         onProviderCommitted: @escaping @MainActor (ProviderInstanceID) async -> Void = { _ in },
         providerRegistry: ModelProviderRegistry? = nil,
         onDefault: @escaping (AppExecutionTarget, Bool) -> Void) {
        let resolvedProviderRegistry = providerRegistry ?? ModelProviderRegistry(provider: provider)
        self.store = store; self.credentials = credentials
        self.providerRegistry = resolvedProviderRegistry
        self.defaults = defaults; self.appearance = appearance; self.menus = menus; self.onDefault = onDefault
        self.onProviderCommitted = onProviderCommitted
        self.onConfigure = onConfigure
        soul = SoulSettingsModel(store: store)
        memory = MemorySettingsModel(runtime: MemoryRuntime(store: store, credentials: credentials))
        let skillsRuntime = SkillRuntime(store: store, credentials: credentials, registry: toolRegistry, stopRuns: onStopExtensionRuns)
        skills = SkillSettingsModel(runtime: skillsRuntime)
        environment = EnvironmentSettingsModel(runtime: EnvironmentRuntime(store: store, credentials: credentials,
            stopRuns: onStopExtensionRuns), skills: skillsRuntime)
        let toolSettings = ToolSettingsModel(store: store, registry: toolRegistry, safetyCap: toolSafetyCap)
        tools = toolSettings
        mcp = MCPSettingsModel(registry: mcpRegistry, runtime: mcpRuntime, store: store,
            credentials: credentials, baseToolRegistry: toolRegistry, toolSettings: toolSettings)
        subagents = SubagentSettingsModel(store: store, providerRegistry: resolvedProviderRegistry, credentials: credentials)
        vectorSearch = VectorSearchSettingsModel(store: store, credentials: credentials, defaults: defaults)
        storage = files.map { SettingsStorageModel(store: store, files: $0) }
        if let instance = defaults.string(forKey: AppShellModel.defaultInstanceIDKey),
           let model = defaults.string(forKey: AppShellModel.defaultModelIDKey) {
            defaultTarget = AppExecutionTarget(providerInstanceID: .init(rawValue: instance), modelID: .init(rawValue: model))
        }
        if let instance = defaults.string(forKey: AppShellModel.imageInputInstanceIDKey),
           let model = defaults.string(forKey: AppShellModel.imageInputModelIDKey),
           !instance.isEmpty, !model.isEmpty {
            imageInputTarget = AppExecutionTarget(providerInstanceID: .init(rawValue: instance),
                modelID: .init(rawValue: model))
        }
    }

    var imageInputAccountName: String? { imageInputCatalogEntry?.instance.displayName }
    var imageInputProviderName: String? { imageInputCatalogEntry?.instance.providerID.displayName }
    var imageInputModelName: String? { imageInputModelDescriptor?.displayName }
    var imageInputEndpointDisplay: String? {
        guard let target = imageInputTarget else { return nil }
        return requestEndpointDisplay(providerInstanceID: target.providerInstanceID, modelID: target.modelID)
    }

    var imageInputAvailabilityMessage: String {
        guard imageInputTarget != nil else { return "未配置图像输入模型。" }
        if isLoading { return "正在读取账户和模型状态。" }
        if catalogLoadErrorMessage != nil { return "账户和模型状态暂不可读取，请重试。" }
        guard let entry = imageInputCatalogEntry else {
            return "不可用：所选账户不存在或已删除。请重新选择账户或清除图像输入配置。"
        }
        guard let descriptor = imageInputModelDescriptor else {
            return "不可用：所选模型已从该账户的 Provider 目录移除。请重新选择或清除配置。"
        }
        guard descriptor.capabilities.contains(.vision) else {
            return "不可用：所选模型不再支持图像输入。请重新选择或清除配置。"
        }
        guard entry.credentialIsActive else {
            return "不可用：\(entry.credentialStatus)。请在 Providers 与账户中修改配置。"
        }
        guard let target = imageInputTarget,
              entry.resolvedEndpointDisplaysByModelID[target.modelID] != nil else {
            return "不可用：实际 endpoint 暂不可解析，请检查账户配置。"
        }
        return "凭据记录已保存，未联网验证；图像输入槽位尚未接入发送流程。"
    }

    func imageInputModels(in entry: SettingsProviderCatalog) -> [ModelDescriptor] {
        entry.models.filter { $0.capabilities.contains(.vision) }
    }

    func requestEndpointDisplay(providerInstanceID: ProviderInstanceID, modelID: ModelID) -> String? {
        guard let entry = catalog.first(where: { $0.id == providerInstanceID }) else { return nil }
        if let endpoint = entry.resolvedEndpointDisplaysByModelID[modelID] {
            return endpoint
        }
        if let baseURL = entry.instance.baseURL, let display = sanitizedEndpointDisplay(baseURL) {
            return "\(display)（配置的 base URL；实际 endpoint 暂不可解析）"
        }
        return nil
    }

    private var imageInputCatalogEntry: SettingsProviderCatalog? {
        guard let target = imageInputTarget else { return nil }
        return catalog.first { $0.id == target.providerInstanceID }
    }

    private var imageInputModelDescriptor: ModelDescriptor? {
        guard let target = imageInputTarget else { return nil }
        return imageInputCatalogEntry?.models.first { $0.id == target.modelID }
    }

    func load() async {
        guard active, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let store = store, credentials = credentials, providerRegistry = providerRegistry
        do {
            let result = try await Task.detached {
                try store.providerInstances().map { instance in
                    let status: String
                    var credentialIsActive = false
                    var credentialMetadata: CredentialMetadata?
                    if let reference = instance.credentialReference {
                        do {
                            if let metadata = try credentials.metadata(for: reference) {
                                credentialMetadata = metadata
                                if metadata.status == .active {
                                    credentialIsActive = true
                                    status = "凭据记录已保存，未联网验证"
                                } else {
                                    status = "需要重新配置凭据"
                                }
                            } else {
                                status = "需要重新配置凭据"
                            }
                        } catch { status = "凭据状态暂不可读" }
                    } else { status = "尚未配置凭据" }
                    let provider = providerRegistry.provider(for: instance.providerID)
                    let models = provider?.knownModels(for: instance) ?? []
                    var resolvedEndpointDisplaysByModelID: [ModelID: String] = [:]
                    if let provider, let metadata = credentialMetadata,
                       metadata.reference == instance.credentialReference {
                        let binding = CredentialBindingSnapshot(reference: metadata.reference,
                            generation: metadata.bindingGeneration)
                        for model in models {
                            if let seed = try? provider.makeRequestConfigSeed(instance: instance,
                                modelID: model.id, credentialBinding: binding),
                               let display = sanitizedEndpointDisplay(seed.endpoint) {
                                resolvedEndpointDisplaysByModelID[model.id] = display
                            }
                        }
                    }
                    return SettingsProviderCatalog(instance: instance,
                        models: models,
                        credentialStatus: status,
                        credentialIsActive: credentialIsActive,
                        resolvedEndpointDisplaysByModelID: resolvedEndpointDisplaysByModelID)
                }
            }.value
            guard active, !Task.isCancelled else { return }
            catalog = result
            hasLoadedProviderCatalog = true
            catalogLoadErrorMessage = nil
            defaultSelectionErrorMessage = nil
            subagents.updateProviderCatalog(result)
        } catch {
            if active {
                let message = "账户和模型读取失败，请重试。"
                catalogLoadErrorMessage = message
                subagents.providerCatalogFailed(message)
            }
        }
        await subagents.load()
        await vectorSearch.load()
    }

    func setDefault(providerInstanceID: ProviderInstanceID, modelID: ModelID) async -> Bool {
        guard active else { return false }
        selection &+= 1
        let request = selection
        isSelectingDefault = true
        defaultSelectionErrorMessage = nil
        defer { if request == selection { isSelectingDefault = false } }
        let store = store, credentials = credentials, providerRegistry = providerRegistry
        do {
            _ = try await Task.detached {
                try AppAssembly.validateTarget(providerInstanceID: providerInstanceID, modelID: modelID,
                    store: store, providerRegistry: providerRegistry, credentials: credentials)
            }.value
            guard active, request == selection, !Task.isCancelled else { return false }
            let target = AppExecutionTarget(providerInstanceID: providerInstanceID, modelID: modelID)
            defaults.set(providerInstanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
            defaults.set(modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
            defaultTarget = target
            onDefault(target, false)
            return true
        } catch {
            if active, request == selection {
                defaultSelectionErrorMessage = "该模型暂不能作为默认，请检查账户和凭据。"
            }
            return false
        }
    }

    func setImageInputModel(providerInstanceID: ProviderInstanceID, modelID: ModelID) async -> Bool {
        guard active else { return false }
        imageInputSelection &+= 1
        let request = imageInputSelection
        isSelectingImageInputModel = true
        imageInputSelectionErrorMessage = nil
        defer {
            if request == imageInputSelection { isSelectingImageInputModel = false }
        }
        let store = store, providerRegistry = providerRegistry
        do {
            try await Task.detached {
                guard let instance = try store.providerInstance(id: providerInstanceID),
                      let provider = providerRegistry.provider(for: instance.providerID),
                      let descriptor = provider.descriptor(for: modelID, in: instance),
                      descriptor.providerInstanceID == instance.id,
                      descriptor.capabilities.contains(.vision) else {
                    throw AppTargetFailure.configurationUnavailable
                }
            }.value
            guard active, request == imageInputSelection, !Task.isCancelled else { return false }
            defaults.set(providerInstanceID.rawValue, forKey: AppShellModel.imageInputInstanceIDKey)
            defaults.set(modelID.rawValue, forKey: AppShellModel.imageInputModelIDKey)
            imageInputTarget = AppExecutionTarget(providerInstanceID: providerInstanceID, modelID: modelID)
            return true
        } catch {
            if active, request == imageInputSelection {
                imageInputSelectionErrorMessage = "该账户或模型当前不可用，或模型未声明图像输入能力；配置未更改。"
            }
            return false
        }
    }

    func clearImageInputModel() {
        guard active else { return }
        imageInputSelection &+= 1
        isSelectingImageInputModel = false
        imageInputSelectionErrorMessage = nil
        defaults.removeObject(forKey: AppShellModel.imageInputInstanceIDKey)
        defaults.removeObject(forKey: AppShellModel.imageInputModelIDKey)
        imageInputTarget = nil
    }

    func configureCapturedConversation(providerInstanceID: ProviderInstanceID, modelID: ModelID) async -> Bool {
        guard active, onConfigure != nil else { return false }
        configurationSelection &+= 1
        let request = configurationSelection
        isConfiguringConversation = true; configurationErrorMessage = nil; configurationStatusMessage = nil
        defer { if request == configurationSelection { isConfiguringConversation = false } }
        let store = store, credentials = credentials, providerRegistry = providerRegistry
        do {
            _ = try await Task.detached {
                try AppAssembly.validateTarget(providerInstanceID: providerInstanceID, modelID: modelID,
                    store: store, providerRegistry: providerRegistry, credentials: credentials)
            }.value
            guard active, request == configurationSelection, !Task.isCancelled else { return false }
            return applyCapturedConfiguration(.init(providerInstanceID: providerInstanceID, modelID: modelID))
        } catch {
            if active, request == configurationSelection {
                configurationErrorMessage = "当前会话配置失败，请检查账户、凭据和模型后重试。"
            }
            return false
        }
    }

    private func applyCapturedConfiguration(_ target: AppExecutionTarget) -> Bool {
        guard active, let onConfigure else { return false }
        configurationStatusMessage = nil
        do {
            guard try onConfigure(target) else {
                configurationErrorMessage = "当前会话已变化或已有配置，未更改其模型。"
                return false
            }
            configurationErrorMessage = nil
            configurationStatusMessage = "当前会话已配置"
            return true
        } catch {
            configurationErrorMessage = "当前会话配置无法保存，原配置已保留。请重试。"
            return false
        }
    }

    func makeProviderSetup() -> ProviderSetupModel? {
        guard active else { return nil }
        return ProviderSetupModel(store: store, credentials: credentials, providerRegistry: providerRegistry, userDefaults: defaults,
            onTargetSaved: { [weak self, onDefault] target in
                self?.defaultTarget = target
                onDefault(target, false)
                guard let self, self.active, self.onConfigure != nil else { return }
                self.configurationSelection &+= 1
                self.isConfiguringConversation = false
                _ = self.applyCapturedConfiguration(target)
            })
    }

    func accountEditor(for instance: ProviderInstance) -> ProviderAccountSettingsModel {
        // Publication remains meaningful after this Settings presentation closes.
        ProviderAccountSettingsModel(store: store, credentials: credentials, instance: instance,
            onCommitted: onProviderCommitted)
    }

    func invalidate() {
        active = false; selection &+= 1; isSelectingDefault = false
        configurationSelection &+= 1; isConfiguringConversation = false
        imageInputSelection &+= 1; isSelectingImageInputModel = false
        soul.invalidate(); memory.invalidate(); skills.invalidate(); environment.invalidate()
        tools.invalidate(); mcp.invalidate(); subagents.invalidate(); storage?.invalidate()
        vectorSearch.invalidate()
    }
}
