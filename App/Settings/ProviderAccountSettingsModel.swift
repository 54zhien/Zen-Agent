import Foundation
import Observation

@MainActor
@Observable
final class ProviderAccountSettingsModel {
    var displayName: String
    var endpoint: String
    var apiKey = ""
    private(set) var instance: ProviderInstance
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let makeCredentialReference: () -> CredentialReference

    init(store: PersistenceStore, credentials: any CredentialStoring, instance: ProviderInstance,
         makeCredentialReference: @escaping () -> CredentialReference = { CredentialReference(id: UUID().uuidString) }) {
        self.store = store; self.credentials = credentials; self.instance = instance
        self.makeCredentialReference = makeCredentialReference
        displayName = instance.displayName; endpoint = instance.baseURL?.absoluteString ?? ""
    }

    func saveConfiguration() async {
        guard !isBusy else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "请输入账户名称。"; return }
        let submittedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if submittedEndpoint.isEmpty { url = nil }
        else {
            guard let parsed = URL(string: submittedEndpoint), parsed.scheme?.lowercased() == "https",
                  let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil,
                  parsed.fragment == nil else {
                errorMessage = "请输入不含用户名或密码的 HTTPS 地址。"; return
            }
            url = parsed
        }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        let store = store, accepted = instance
        do {
            instance = try await Task.detached {
                try store.reconfigureProviderInstance(id: accepted.id, displayName: name,
                    baseURL: url, expectedEditRevision: accepted.editRevision)
            }.value
            statusMessage = "账户资料已保存。"
        } catch { errorMessage = "资料保存失败或账户已变化。本页修改已保留，请重新检查账户。" }
    }

    func reauthenticate() async {
        guard !isBusy else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入 API Key。"; return
        }
        isBusy = true; errorMessage = nil; statusMessage = nil
        defer { isBusy = false }
        let store = store, credentials = credentials, accepted = instance
        let fresh = makeCredentialReference(), secret = SecretValue(apiKey)
        do {
            instance = try await Task.detached {
                // Ownership is acquired only after provision succeeds. An ID collision
                // must never authorize cleanup of someone else's reference.
                try credentials.provision(secret, as: fresh, principalFingerprint: nil, at: Date())
                do {
                    return try store.attachCredential(fresh, toInstance: accepted.id,
                        expectedEditRevision: accepted.editRevision)
                } catch {
                    // These domain failures roll the transaction back. An unknown
                    // persistence outcome is not proof that publication did not occur.
                    if let failure = error as? PersistenceError {
                        switch failure {
                        case .providerInstanceEditConflict, .providerInstanceNotFound:
                            guard try !store.providerInstances().contains(where: { $0.credentialReference == fresh }) else { throw error }
                            try credentials.logout(fresh, at: Date())
                        default: break
                        }
                    }
                    throw error
                }
            }.value
            apiKey = ""
            statusMessage = "凭据已保存，尚未联网验证。"
        } catch { errorMessage = "重认证未完成，账户资料和输入已保留。请检查账户后重试。" }
    }
}
