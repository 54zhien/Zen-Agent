import Foundation
import Observation

struct VectorSearchAccountOption: Equatable, Identifiable, Sendable {
    let instance: ProviderInstance
    let credentialStatus: String

    var id: ProviderInstanceID { instance.id }
    var endpointAddress: String { VectorSearchEndpoint.authority(for: instance) }
    var title: String { "\(instance.displayName) · \(endpointAddress) · \(credentialStatus)" }
}

enum VectorSearchEndpoint {
    static func authority(for instance: ProviderInstance) -> String {
        let url = OpenAIProvider.resolvedEndpoint(for: instance)
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)
        let host = url.host!
        return "\(host):\(port)"
    }
}

@MainActor
@Observable
final class VectorSearchSettingsModel {
    static let selectedAccountKey = "zenagent.semanticSearch.providerInstanceID"

    private(set) var accounts: [VectorSearchAccountOption] = []
    private(set) var selectedProviderInstanceID: ProviderInstanceID?
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var active = true

    init(store: PersistenceStore, credentials: any CredentialStoring, defaults: UserDefaults) {
        self.store = store
        self.credentials = credentials
        self.defaults = defaults
    }

    func load() async {
        guard active, !isLoading else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        let store = store
        let credentials = credentials
        do {
            let accounts = try await Task.detached {
                try store.providerInstances()
                    .filter { $0.providerID == .openAI }
                    .map { instance in
                        let status: String
                        guard let reference = instance.credentialReference else {
                            return VectorSearchAccountOption(instance: instance, credentialStatus: "未配置凭据")
                        }
                        do {
                            if let metadata = try credentials.metadata(for: reference) {
                                status = metadata.status == .active ? "凭据记录有效" : "需重新验证"
                            } else {
                                status = "凭据记录缺失"
                            }
                        } catch {
                            status = "凭据状态暂不可读"
                        }
                        return VectorSearchAccountOption(instance: instance, credentialStatus: status)
                    }
                    .sorted {
                        let order = $0.instance.displayName.localizedCaseInsensitiveCompare($1.instance.displayName)
                        return order == .orderedSame ? $0.id.rawValue < $1.id.rawValue : order == .orderedAscending
                    }
            }.value
            guard active, !Task.isCancelled else { return }
            self.accounts = accounts
            if let rawValue = defaults.string(forKey: Self.selectedAccountKey),
               let account = accounts.first(where: { $0.id.rawValue == rawValue }) {
                selectedProviderInstanceID = account.id
            } else {
                selectedProviderInstanceID = nil
            }
            isLoaded = true
        } catch {
            guard active else { return }
            errorMessage = "OpenAI 账户读取失败，请重试。"
        }
    }

    func selectAccount(_ id: ProviderInstanceID?) {
        guard active else { return }
        if let id, !accounts.contains(where: { $0.id == id }) { return }
        selectedProviderInstanceID = id
        if let id {
            defaults.set(id.rawValue, forKey: Self.selectedAccountKey)
            statusMessage = "语义搜索将使用所选 OpenAI 账户。"
        } else {
            defaults.removeObject(forKey: Self.selectedAccountKey)
            statusMessage = "请在执行语义搜索前选择 OpenAI 账户。"
        }
    }

    func invalidate() { active = false }
}
