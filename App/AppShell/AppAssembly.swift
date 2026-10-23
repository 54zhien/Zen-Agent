import Foundation

enum AppTargetFailure: Error, Equatable, Sendable {
    case configurationUnavailable
    case keyMissing
    case keychainUnavailable
    case credentialFailed
    case authenticationRequired
    case bindingMoved
    case persistenceUnavailable

    var message: String {
        switch self {
        case .configurationUnavailable:
            return "当前模型配置不可用"
        case .keyMissing:
            return "Key 缺失"
        case .keychainUnavailable:
            return "Keychain 不可用"
        case .credentialFailed:
            return "凭据存储异常"
        case .authenticationRequired:
            return "请重新配置 API Key"
        case .bindingMoved:
            return "凭据配置已变化，请重新验证"
        case .persistenceUnavailable:
            return "无法读取模型配置"
        }
    }
}

enum AppAssemblyFailure: Error, Equatable {
    case database(summary: String)
    case wiring(summary: String)

    var title: String {
        switch self {
        case .database:
            return "无法打开会话数据"
        case .wiring:
            return "无法完成应用装配"
        }
    }

    var summary: String {
        switch self {
        case .database(let summary), .wiring(let summary):
            return summary
        }
    }
}

struct AppAssembly {
    struct Dependencies {
        let store: PersistenceStore
        let credentials: any CredentialStoring
        let provider: any ModelProvider
        let runtime: ConversationRuntime
        let router: RunEventRouter
        let managedFiles: ManagedFileStore?
        let toolRegistry: ToolRegistry
        let toolSafetyCap: ToolPolicySafetyCap
        let sessions: ConversationSessionStore?

        init(store: PersistenceStore, credentials: any CredentialStoring, provider: any ModelProvider,
             runtime: ConversationRuntime, router: RunEventRouter, managedFiles: ManagedFileStore? = nil,
             toolRegistry: ToolRegistry = .empty, toolSafetyCap: ToolPolicySafetyCap = .unrestricted,
             sessions: ConversationSessionStore? = nil) {
            self.store = store; self.credentials = credentials; self.provider = provider
            self.runtime = runtime; self.router = router; self.managedFiles = managedFiles
            self.toolRegistry = toolRegistry; self.toolSafetyCap = toolSafetyCap; self.sessions = sessions
        }
    }

    @MainActor
    static func assemble(router: RunEventRouter, sessions: ConversationSessionStore) throws -> Dependencies {
        let database: ZenDatabase
        do {
            let supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            // New SQLite sidecars inherit the same explicitly chosen protection.
            // Memory shares User Data backup; this is not app cloud sync.
            try UserDataFileProtection.apply(to: supportDirectory.path)
            var backedUpDirectory = supportDirectory
            var backupValues = URLResourceValues()
            backupValues.isExcludedFromBackup = false
            try backedUpDirectory.setResourceValues(backupValues)
            database = try ZenDatabase.open(
                at: supportDirectory.appending(path: "ZenAgent.sqlite").path
            )
        } catch {
            throw AppAssemblyFailure.database(summary: safeSummary(for: error))
        }

        let store = PersistenceStore(database: database)
        let credentials = CredentialStore(
            secrets: KeychainSecretBackend(),
            metadataRepository: store
        )
        let transport = LiveHTTPTransport.make()
        let provider = DeepSeekProvider(transport: transport)
        let managedFiles = try ManagedFileStore.applicationDefault()
        let toolRegistry = try ToolRegistry(tools: [CalculatorTool(), CurrentDateTool(), DeviceInfoTool(),
            FilesTool(files: managedFiles, store: store, sessions: sessions)])
        let runtime = makeRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: toolRegistry,
            managedFiles: managedFiles
        )
        return Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router,
            managedFiles: managedFiles,
            toolRegistry: toolRegistry,
            sessions: sessions
        )
    }

    static func makeRuntime(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        router: RunEventRouter,
        toolRegistry: ToolRegistry,
        managedFiles: ManagedFileStore? = nil,
        toolSafetyCap: ToolPolicySafetyCap = .unrestricted
    ) -> ConversationRuntime {
        // The shell owns presentation routing. A cached Send bridge retains
        // Runtime; retaining Router here would cycle through its registered Pane
        // and Session, keeping the database alive after the shell is discarded.
        ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            onEvent: { [weak router] event in
                await router?.handle(event)
            },
            registerRecoveredRun: { [weak router] runID, conversationID in
                await router?.registerRecoveredRun(
                    runID: runID,
                    conversationID: conversationID
                )
            },
            toolRegistry: toolRegistry,
            toolRuntime: ToolRuntime(store: store, registry: toolRegistry, safetyCap: toolSafetyCap, credentials: credentials),
            managedFileStore: managedFiles
        )
    }

    static func validateTarget(
        providerInstanceID: ProviderInstanceID,
        modelID: ModelID,
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring
    ) throws -> ProviderInstance {
        let instance: ProviderInstance
        do {
            guard let stored = try store.providerInstance(id: providerInstanceID) else {
                throw AppTargetFailure.configurationUnavailable
            }
            instance = stored
        } catch let failure as AppTargetFailure {
            throw failure
        } catch {
            throw AppTargetFailure.persistenceUnavailable
        }

        guard instance.providerID == provider.id else {
            throw AppTargetFailure.configurationUnavailable
        }
        guard let descriptor = provider.knownModels(for: instance).first(where: {
            $0.id == modelID && $0.providerInstanceID == instance.id
        }), descriptor.capabilities.contains(.text), descriptor.capabilities.contains(.streaming) else {
            throw AppTargetFailure.configurationUnavailable
        }
        guard let reference = instance.credentialReference else {
            throw AppTargetFailure.keyMissing
        }

        let metadata: CredentialMetadata
        do {
            guard let stored = try credentials.metadata(for: reference) else {
                throw AppTargetFailure.keyMissing
            }
            metadata = stored
        } catch let failure as AppTargetFailure {
            throw failure
        } catch {
            throw AppTargetFailure.credentialFailed
        }
        guard metadata.status == .active else {
            throw AppTargetFailure.authenticationRequired
        }

        do {
            guard try credentials.resolve(
                frozenReference: metadata.reference,
                generation: metadata.bindingGeneration
            ) != nil else {
                throw AppTargetFailure.keyMissing
            }
        } catch let failure as AppTargetFailure {
            throw failure
        } catch let error as CredentialError {
            switch error {
            case .unavailable:
                throw AppTargetFailure.keychainUnavailable
            case .failed:
                throw AppTargetFailure.credentialFailed
            case .authenticationRequired:
                throw AppTargetFailure.authenticationRequired
            case .bindingMoved:
                throw AppTargetFailure.bindingMoved
            case .alreadyExists, .notFound:
                throw AppTargetFailure.keyMissing
            }
        } catch {
            throw AppTargetFailure.credentialFailed
        }

        return instance
    }

    static func wireConversation(
        id: String,
        dependencies: Dependencies,
        onTargetFailure: @escaping @MainActor @Sendable (AppTargetFailure, AppExecutionTarget) -> Void = { _, _ in }
    ) -> ComposerRuntimeActionBridge {
        let startContext = ConversationStartContext(
            conversationID: id,
            store: dependencies.store,
            provider: dependencies.provider,
            credentials: dependencies.credentials,
            runtime: dependencies.runtime,
            onTargetFailure: onTargetFailure
        )
        let runtime = dependencies.runtime
        return ComposerRuntimeActionBridge(
            start: { command in
                try await startContext.start(
                    command,
                    initiatedAt: ComposerSendTiming.initiatedAt ?? Date()
                )
            },
            stop: { runID in
                try await runtime.stop(runID: runID)
            },
            models: { providerInstanceID in
                try await runtime.knownModels(for: providerInstanceID)
            },
            projection: { conversationID in
                try await runtime.projection(conversationID: conversationID)
            },
            projectionUpdates: { conversationID in
                await runtime.projectionUpdates(conversationID: conversationID)
            },
            skills: { instanceID, modelID in
                try await runtime.availableSkills(providerInstanceID: instanceID, modelID: modelID)
            }
        )
    }

    private static func safeSummary(for error: Error) -> String {
        let code = (error as NSError).code
        return "\(String(reflecting: type(of: error))) (code \(code))"
    }
}

actor ConversationStartContext {
    private let conversationID: String
    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring
    private let runtime: ConversationRuntime
    private let onTargetFailure: @MainActor @Sendable (AppTargetFailure, AppExecutionTarget) -> Void
    private var pendingConversation: ConversationRecord?
    private var isPersisted = false

    init(
        conversationID: String,
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        runtime: ConversationRuntime,
        onTargetFailure: @escaping @MainActor @Sendable (AppTargetFailure, AppExecutionTarget) -> Void
    ) {
        self.conversationID = conversationID
        self.store = store
        self.provider = provider
        self.credentials = credentials
        self.runtime = runtime
        self.onTargetFailure = onTargetFailure
    }

    func start(_ command: SendCommand, initiatedAt: Date) async throws -> String {
        guard command.conversationID == conversationID else {
            throw ComposerSendFailure.configurationUnavailable
        }
        if pendingConversation == nil, !isPersisted {
            pendingConversation = ConversationRecord(
                id: conversationID,
                title: "",
                createdAt: initiatedAt,
                updatedAt: initiatedAt,
                userActiveAt: initiatedAt,
                pinned: false,
                lifecycle: .visible
            )
        }

        do {
            try AppAssembly.validateTarget(
                providerInstanceID: command.providerInstanceID,
                modelID: command.modelID,
                store: store,
                provider: provider,
                credentials: credentials
            )
        } catch let failure as AppTargetFailure {
            await onTargetFailure(failure, AppExecutionTarget(
                providerInstanceID: command.providerInstanceID,
                modelID: command.modelID
            ))
            switch failure {
            case .keyMissing:
                throw ComposerSendFailure.keyMissing
            case .keychainUnavailable:
                throw ComposerSendFailure.keychainUnavailable
            default:
                throw ComposerSendFailure.configurationUnavailable
            }
        }

        do {
            let runID = try await runtime.start(
                command,
                creatingConversationIfMissing: isPersisted ? nil : pendingConversation,
                initiatedAt: initiatedAt
            )
            if try store.conversation(id: conversationID) != nil {
                isPersisted = true
            }
            return runID
        } catch {
            // An existing submission with another payload is a rejected Send,
            // never evidence that this draft was committed.
            if case ConversationRuntimeError.submissionIDPayloadConflict = error { throw error }
            if case PersistenceError.submissionIDPayloadConflict = error { throw error }
            do {
                if try store.conversation(id: conversationID) != nil {
                    isPersisted = true
                    if let committedRun = try store.run(submissionID: command.submissionID) {
                        throw ComposerSendFailure.committed(runID: committedRun.id)
                    }
                }
            } catch let committed as ComposerSendFailure {
                throw committed
            } catch {
                throw ComposerSendFailure.configurationUnavailable
            }
            throw error
        }
    }
}
