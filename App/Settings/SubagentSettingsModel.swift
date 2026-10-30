import Foundation
import Observation

struct SubagentModelOption: Identifiable {
    let target: DelegationModelTarget
    let providerName: String
    let modelName: String

    var id: String {
        "\(target.providerInstanceID.rawValue.utf8.count):\(target.providerInstanceID.rawValue)\(target.modelID.rawValue)"
    }

    var title: String { "\(providerName) · \(modelName)" }
}

enum SubagentModelSelection: Hashable {
    case followParent
    case explicit(ProviderInstanceID, ModelID)
    case unavailable
}

@MainActor
@Observable
final class SubagentSettingsModel {
    private(set) var configuration: DelegationRuntimeConfiguration?
    private(set) var providerCatalog: [SettingsProviderCatalog] = []
    private(set) var isCatalogLoaded = false
    private(set) var catalogErrorMessage: String?
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?

    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let provider: any ModelProvider
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private var active = true

    init(store: PersistenceStore, provider: any ModelProvider, credentials: any CredentialStoring) {
        self.store = store
        self.provider = provider
        self.credentials = credentials
    }

    var modelOptions: [SubagentModelOption] {
        guard isCatalogLoaded else { return [] }
        var options: [SubagentModelOption] = []
        for entry in providerCatalog {
            guard entry.instance.providerID == provider.id, entry.credentialIsActive else { continue }
            options.append(contentsOf: entry.models.compactMap { descriptor in
                guard descriptor.providerInstanceID == entry.instance.id,
                      descriptor.capabilities.contains(.text),
                      descriptor.capabilities.contains(.streaming) else { return nil }
                return SubagentModelOption(
                    target: DelegationModelTarget(
                        providerInstanceID: entry.instance.id,
                        modelID: descriptor.id
                    ),
                    providerName: entry.instance.displayName,
                    modelName: descriptor.displayName
                )
            })
        }
        return options
    }

    var modelSelection: SubagentModelSelection {
        guard let target = configuration?.explicitModelTarget else { return .followParent }
        guard isCatalogLoaded, modelOptions.contains(where: { $0.target == target }) else { return .unavailable }
        return .explicit(target.providerInstanceID, target.modelID)
    }

    func updateProviderCatalog(_ catalog: [SettingsProviderCatalog]) {
        providerCatalog = catalog
        isCatalogLoaded = true
        catalogErrorMessage = nil
    }

    func providerCatalogFailed(_ message: String) {
        isCatalogLoaded = false
        catalogErrorMessage = message
    }

    func load() async {
        guard active, !isBusy else { return }
        isBusy = true
        isLoaded = false
        errorMessage = nil
        defer { isBusy = false }
        let store = store
        do {
            let configuration = try await Task.detached {
                try store.delegationConfiguration()
            }.value
            guard active, !Task.isCancelled else { return }
            self.configuration = configuration
            isLoaded = true
        } catch {
            guard active else { return }
            errorMessage = "子代理设置读取失败，请重试。"
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard let configuration else { return }
        await save(enabled: enabled, explicitModelTarget: configuration.explicitModelTarget, validateTarget: false)
    }

    func setExplicitModelTarget(_ target: DelegationModelTarget?) async {
        guard let configuration else { return }
        guard configuration.explicitModelTarget != target else { return }
        await save(enabled: configuration.enabled, explicitModelTarget: target, validateTarget: target != nil)
    }

    func invalidate() {
        active = false
    }

    private func save(
        enabled: Bool,
        explicitModelTarget: DelegationModelTarget?,
        validateTarget: Bool
    ) async {
        guard active, isLoaded, !isBusy else { return }
        if validateTarget, let explicitModelTarget {
            guard modelOptions.contains(where: { $0.target == explicitModelTarget }) else {
                errorMessage = "请选择当前可用的 Provider 与模型。"
                return
            }
        }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }

        let store = store
        let provider = provider
        let credentials = credentials
        do {
            if validateTarget, let explicitModelTarget {
                _ = try await Task.detached {
                    try AppAssembly.validateTarget(
                        providerInstanceID: explicitModelTarget.providerInstanceID,
                        modelID: explicitModelTarget.modelID,
                        store: store,
                        provider: provider,
                        credentials: credentials
                    )
                }.value
                guard active, !Task.isCancelled else { return }
            }
            let updated = try await Task.detached {
                try store.setDelegationConfiguration(
                    enabled: enabled,
                    explicitModelTarget: explicitModelTarget
                )
            }.value
            guard active, !Task.isCancelled else { return }
            configuration = updated
            statusMessage = "子代理设置已保存。"
        } catch let failure as AppTargetFailure {
            guard active else { return }
            errorMessage = failure.message + "。请到 Providers 与账户中检查配置后重试。"
        } catch {
            guard active else { return }
            errorMessage = "子代理设置保存失败，原配置已保留。"
        }
    }
}
