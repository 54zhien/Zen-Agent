import Foundation

/// Definition lifecycle and workflow selection; ToolRuntime retains all authority.
struct SkillRuntime: Sendable {
    let store: PersistenceStore
    let credentials: any CredentialStoring
    let registry: ToolRegistry
    let stopRuns: EnvironmentRuntime.StopRuns?
    let availableMCPServerIDs: Set<String>?
    let availableMCPServerIdentities: [String: MCPServerDependencyIdentity]?
    let frozenMCPServerDependencies: [MCPServerDependencyIdentity]?

    init(store: PersistenceStore, credentials: any CredentialStoring, registry: ToolRegistry,
         stopRuns: EnvironmentRuntime.StopRuns? = nil, availableMCPServerIDs: Set<String>? = nil,
         availableMCPServerIdentities: [String: MCPServerDependencyIdentity]? = nil,
         frozenMCPServerDependencies: [MCPServerDependencyIdentity]? = nil) {
        self.store = store; self.credentials = credentials; self.registry = registry; self.stopRuns = stopRuns
        self.availableMCPServerIDs = availableMCPServerIDs
        self.availableMCPServerIdentities = availableMCPServerIdentities
        self.frozenMCPServerDependencies = frozenMCPServerDependencies
    }
    func list() throws -> [SkillItem] {
        try store.seedSkillCatalog()
        return try store.skills()
    }
    func dependencyStatus(for item: SkillItem) throws -> SkillDependencyStatus {
        var status = SkillDependencyStatus()
        for tool in item.definition.requiredTools where registry.descriptor(id: tool) == nil {
            status.missing.append("缺少工具：\(tool)")
        }
        for server in item.definition.requiredMCPServers where currentMCPServerIdentities[server] == nil {
            status.missing.append("MCP 服务未连接或身份已变化：\(server)")
        }
        for tool in item.definition.optionalTools where registry.descriptor(id: tool) == nil {
            status.notices.append("可选工具未安装：\(tool)")
        }
        do { _ = try environment.bind(skillID: item.id, declaredKeys: item.definition.environmentKeys) }
        catch { status.missing.append("环境变量缺失、已撤销或引用无效") }
        status.notices.append("工具仍按各自策略执行；需要询问或已拒绝的操作不会因启用 Skill 而放行。")
        return status
    }
    func copyDefinition(id: String) throws -> SkillDefinition {
        guard let item = try list().first(where: { $0.id == id && !$0.pendingDeletion }) else { throw SkillError.notFound }
        var definition = item.definition
        definition.name = String(definition.name.prefix(60)) + " 副本"
        return definition
    }
    @discardableResult
    func saveUser(id: String? = nil, expectedRevisionID: String? = nil, definition: SkillDefinition) throws -> SkillItem {
        try store.memoryAccessGate.environmentCredentialLock.withLock {
            if let id, let item = try list().first(where: { $0.id == id }), item.source == .builtIn { throw SkillError.builtInReadOnly }
            guard SkillValidation.allows(definition) else { throw SkillError.invalidDefinition }
            do {
                let content = [definition.name, definition.summary, definition.instructions]
                    + definition.requiredTools + definition.optionalTools + definition.requiredMCPServers
                    + definition.environmentKeys + definition.triggerTerms
                for value in content {
                    guard try SecretContentGuard.allows(value, store: store, credentials: credentials) else { throw SkillError.unsafeContent }
                }
            } catch SkillError.unsafeContent { throw SkillError.unsafeContent }
            catch { throw SkillError.validationUnavailable }
            return try store.saveUserSkill(id: id, expectedRevisionID: expectedRevisionID, definition: definition)
        }
    }
    func dependencies(id: String) throws -> ExtensionDependencySummary {
        .init(activeRunIDs: try store.skillDependentRunIDs(id: id))
    }
    func setEnabled(id: String, enabled: Bool) async throws {
        if enabled { try store.enableSkill(id: id); return }
        let runs = try await store.memoryAccessGate.withWrite { try store.revokeSkill(id: id, deleting: false) }
        try await settle(runs)
    }
    func delete(id: String) async throws {
        let runs = try await store.memoryAccessGate.withWrite { try store.revokeSkill(id: id, deleting: true) }
        try await settle(runs)
        for variable in try environment.list() where variable.scope == .skill(id) { try await environment.delete(id: variable.id) }
        try await store.memoryAccessGate.withWrite { try store.finishSkillDeletion(id: id) }
        try environment.retryCredentialCleanup()
    }
    func prepare(query: String, selectedSkillIDs: [String]) throws -> [SkillContext] {
        guard selectedSkillIDs.count <= SkillRouter.maximumActivatedSkills,
              Set(selectedSkillIDs).count == selectedSkillIDs.count else { throw SkillError.invalidDefinition }
        let items = try list()
        let selected: [SkillItem]
        if selectedSkillIDs.isEmpty {
            let available = try items.filter { item in
                guard item.enabled, !item.pendingDeletion else { return false }
                return try dependencyStatus(for: item).isAvailable
            }
            selected = SkillRouter.select(query: query, candidates: available)
        } else {
            selected = try selectedSkillIDs.sorted().map { id in
                guard let item = items.first(where: { $0.id == id && !$0.pendingDeletion }) else { throw SkillError.notFound }
                guard item.enabled else { throw SkillError.disabled }
                guard try dependencyStatus(for: item).isAvailable else { throw SkillError.missingDependency }
                return item
            }
        }
        return try selected.map { item in
            let binding = try environment.bind(skillID: item.id, declaredKeys: item.definition.environmentKeys)
            return try context(item, reference: .init(skillID: item.id, revisionID: item.revisionID,
                environmentReferences: binding.references, environmentFingerprint: binding.fingerprint))
        }
    }
    func resolveFrozen(_ references: [SkillActivationReference]) throws -> [SkillContext] {
        let items = try store.resolveSkillItems(references)
        let current = currentMCPServerIdentities
        let frozen = Dictionary(uniqueKeysWithValues: (frozenMCPServerDependencies ?? Array(current.values)).map {
            ($0.serverID, $0)
        })
        return try zip(items, references).map { item, reference in
            guard item.definition.requiredTools.allSatisfy({ registry.descriptor(id: $0) != nil }),
                  item.definition.requiredMCPServers.allSatisfy({
                      current[$0] != nil && current[$0] == frozen[$0]
                  }) else { throw SkillError.erasedDependency }
            return try context(item, reference: reference)
        }
    }

    func requiredMCPServerDependencies(
        for references: [SkillActivationReference]
    ) throws -> [MCPServerDependencyIdentity] {
        let requiredIDs = Set(try store.resolveSkillItems(references).flatMap {
            $0.definition.requiredMCPServers
        })
        let current = currentMCPServerIdentities
        guard requiredIDs.allSatisfy({ current[$0] != nil }) else {
            throw SkillError.missingDependency
        }
        return requiredIDs.compactMap { current[$0] }.sorted { $0.serverID < $1.serverID }
    }

    private var currentMCPServerIdentities: [String: MCPServerDependencyIdentity] {
        let identities = availableMCPServerIdentities ?? registry.mcpServerDependencyIdentities
        let serverIDs = availableMCPServerIDs ?? Set(identities.keys)
        return identities.filter { serverIDs.contains($0.key) }
    }

    private var environment: EnvironmentRuntime { .init(store: store, credentials: credentials, stopRuns: stopRuns) }

    private func context(_ item: SkillItem, reference: SkillActivationReference) throws -> SkillContext {
        let instructions = try environment.interpolate(item.definition.instructions,
            binding: .init(references: reference.environmentReferences, fingerprint: reference.environmentFingerprint),
            skillID: item.id, declaredKeys: item.definition.environmentKeys)
        guard instructions.utf8.count <= 8_192 else { throw SkillError.invalidDefinition }
        guard try SecretContentGuard.allows(instructions, store: store, credentials: credentials),
              try SecretContentGuard.allows(item.definition.name, store: store, credentials: credentials) else { throw SkillError.unsafeContent }
        return .init(reference: reference, name: item.definition.name, instructions: instructions)
    }

    private func settle(_ runs: [String]) async throws {
        guard !runs.isEmpty else { return }
        guard let stopRuns else { throw SkillError.resourceInUse }
        do { try await stopRuns(runs) } catch { throw SkillError.resourceInUse }
    }
}
