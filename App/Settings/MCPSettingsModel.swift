import Foundation
import Observation

struct MCPSettingsCredentialOption: Sendable, Identifiable {
    let id: String
    let title: String
    let reference: MCPAuthenticationReference
}

@MainActor
@Observable
final class MCPSettingsModel {
    private(set) var servers: [MCPServer] = []
    private(set) var snapshots: [String: MCPServerConnectionSnapshot] = [:]
    private(set) var credentialOptions: [MCPSettingsCredentialOption] = []
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?

    @ObservationIgnored private let registry: MCPServerRegistry
    @ObservationIgnored private let runtime: MCPServerRuntime
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let baseToolRegistry: ToolRegistry
    @ObservationIgnored private let toolSettings: ToolSettingsModel
    @ObservationIgnored private var active = true

    init(registry: MCPServerRegistry, runtime: MCPServerRuntime, store: PersistenceStore,
         credentials: any CredentialStoring, baseToolRegistry: ToolRegistry,
         toolSettings: ToolSettingsModel) {
        self.registry = registry
        self.runtime = runtime
        self.store = store
        self.credentials = credentials
        self.baseToolRegistry = baseToolRegistry
        self.toolSettings = toolSettings
    }

    func snapshot(for server: MCPServer) -> MCPServerConnectionSnapshot {
        snapshots[server.id] ?? .configuration(server: server)
    }

    func authenticationOptionID(for reference: MCPAuthenticationReference?) -> String {
        guard let reference else { return "" }
        return Self.optionID(for: reference)
    }

    func authenticationOptions(for reference: MCPAuthenticationReference?) -> [MCPSettingsCredentialOption] {
        guard let reference,
              !credentialOptions.contains(where: { $0.id == Self.optionID(for: reference) }) else {
            return credentialOptions
        }
        return credentialOptions + [MCPSettingsCredentialOption(
            id: Self.optionID(for: reference), title: "已配置凭据当前不可用", reference: reference
        )]
    }

    func load() async {
        guard active, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await reload()
    }

    private func reload() async {
        guard active else { return }
        let registry = registry, store = store, credentials = credentials
        do {
            let configuration = try await Task.detached {
                let servers = try registry.list()
                let providers = try store.providerInstances()
                let environments = try store.environmentVariables()
                var options: [MCPSettingsCredentialOption] = []
                for provider in providers {
                    guard let reference = provider.credentialReference,
                          try credentials.metadata(for: reference)?.status == .active else { continue }
                    let authentication = MCPAuthenticationReference.credential(reference)
                    options.append(.init(id: Self.optionID(for: authentication),
                        title: "\(provider.displayName) · Provider 凭据", reference: authentication))
                }
                for item in environments where item.scope == .global {
                    guard case .secret(let binding) = item.value,
                          try credentials.metadata(for: binding.reference)?.status == .active else { continue }
                    let authentication = MCPAuthenticationReference.globalEnvironment(item.reference)
                    options.append(.init(id: Self.optionID(for: authentication),
                        title: "\(item.key) · 全局密钥", reference: authentication))
                }
                return (servers, options)
            }.value
            guard active, !Task.isCancelled else { return }
            servers = configuration.0
            credentialOptions = configuration.1.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            isLoaded = true
            errorMessage = nil
        } catch {
            guard active else { return }
            errorMessage = "MCP 服务配置读取失败，请重试。"
            return
        }

        do {
            let current = try await runtime.snapshots()
            guard active, !Task.isCancelled else { return }
            snapshots = Dictionary(uniqueKeysWithValues: current.map { ($0.serverID, $0) })
            await refreshToolPolicyRegistry()
        } catch {
            guard active else { return }
            errorMessage = "MCP 连接状态暂时无法读取，请重试。"
        }
    }

    func save(serverID: String?, displayName: String, endpoint: String,
              authenticationOptionID: String) async -> MCPServer? {
        guard active, !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingReference = servers.first(where: { $0.id == serverID })?.authenticationReference
        let reference = authenticationOptionID.isEmpty ? nil : credentialOptions.first {
            $0.id == authenticationOptionID
        }?.reference ?? existingReference.flatMap {
            Self.optionID(for: $0) == authenticationOptionID ? $0 : nil
        }
        if let serverID, let existing = servers.first(where: { $0.id == serverID }),
           (existing.displayName != name || existing.endpoint != url || existing.authenticationReference != reference) {
            snapshots[serverID] = await runtime.disconnect(serverID: serverID)
        }
        let registry = registry
        do {
            let saved = try await Task.detached { () throws -> MCPServer in
                var result: MCPServer
                if let serverID {
                    result = try registry.update(id: serverID, displayName: name, endpoint: url)
                } else {
                    result = try registry.create(displayName: name, endpoint: url)
                }
                if result.authenticationReference != reference {
                    result = try registry.setAuthenticationReference(id: result.id, reference: reference)
                }
                return result
            }.value
            guard active else { return nil }
            await reload()
            statusMessage = "MCP 服务配置已保存。"
            return saved
        } catch {
            guard active else { return nil }
            errorMessage = "MCP 服务配置保存失败，请检查后重试。"
            return nil
        }
    }

    func setEnabled(serverID: String, enabled: Bool) async {
        guard active, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        if !enabled {
            snapshots[serverID] = await runtime.disconnect(serverID: serverID)
        }
        let registry = registry
        do {
            _ = try await Task.detached { try registry.setEnabled(id: serverID, enabled: enabled) }.value
            guard active else { return }
            await reload()
            statusMessage = enabled ? "MCP 服务已启用。" : "MCP 服务已停用。"
        } catch {
            guard active else { return }
            await reload()
            errorMessage = "MCP 服务启用状态保存失败，请重试。"
        }
    }

    func connect(serverID: String) async {
        guard active, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            snapshots[serverID] = try await runtime.connect(serverID: serverID)
            guard active else { return }
            await refreshToolPolicyRegistry()
            statusMessage = "MCP 服务已连接。"
        } catch {
            guard active else { return }
            await reload()
            errorMessage = "MCP 服务连接失败；请检查地址、凭据和服务状态。"
        }
    }

    func disconnect(serverID: String) async {
        guard active, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        snapshots[serverID] = await runtime.disconnect(serverID: serverID)
        guard active else { return }
        await refreshToolPolicyRegistry()
        statusMessage = "MCP 服务已断开。"
    }

    func reconnect(serverID: String) async {
        guard active, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        _ = await runtime.disconnect(serverID: serverID)
        do {
            snapshots[serverID] = try await runtime.connect(serverID: serverID)
            guard active else { return }
            await refreshToolPolicyRegistry()
            statusMessage = "MCP 服务已重新连接。"
        } catch {
            guard active else { return }
            await reload()
            errorMessage = "MCP 服务重连失败；请检查地址、凭据和服务状态。"
        }
    }

    func delete(serverID: String) async -> Bool {
        guard active, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        _ = await runtime.disconnect(serverID: serverID)
        let registry = registry
        do {
            try await Task.detached { try registry.delete(id: serverID) }.value
            guard active else { return false }
            await reload()
            statusMessage = "MCP 服务已删除。"
            return !servers.contains { $0.id == serverID }
        } catch {
            guard active else { return false }
            await reload()
            errorMessage = "MCP 服务删除失败；相关运行结束后请重试。"
            return false
        }
    }

    func reconnectEnabledServers() async {
        guard active, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        await runtime.reconnectEnabledServers()
        guard active else { return }
        await reload()
    }

    func invalidate() { active = false }

    private func refreshToolPolicyRegistry() async {
        guard active else { return }
        do {
            let registry = try await runtime.unifiedToolRegistry(base: baseToolRegistry)
            guard active else { return }
            let disconnectedDescriptors = snapshots.values
                .filter { $0.state != .connected }
                .flatMap(\.toolDescriptors)
            await toolSettings.replaceRegistry(registry, disconnectedDescriptors: disconnectedDescriptors)
        } catch {
            guard active else { return }
            errorMessage = "MCP 工具策略暂时无法刷新，请重试。"
        }
    }

    nonisolated private static func optionID(for reference: MCPAuthenticationReference) -> String {
        switch reference {
        case .credential(let credential):
            "credential:\(credential.kind.rawValue):\(credential.id)"
        case .globalEnvironment(let environment):
            "environment:\(environment.variableID):\(environment.revisionID)"
        }
    }
}
