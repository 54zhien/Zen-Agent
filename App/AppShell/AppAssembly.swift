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
            return "凭据读取失败，请稍后重试"
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
    typealias ConfirmationReadOperation = @Sendable () async -> ComposerSendConfirmationResult
    typealias ConfirmationReadInterceptor = @Sendable (
        SendCommand,
        String?,
        ConfirmationReadOperation
    ) async -> ComposerSendConfirmationResult

    struct Dependencies {
        let store: PersistenceStore
        let credentials: any CredentialStoring
        let provider: any ModelProvider
        let runtime: ConversationRuntime
        let router: RunEventRouter
    }

    static func assemble(router: RunEventRouter) throws -> Dependencies {
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
        let toolRegistry = ToolRegistry.empty
        let runtime = makeRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: toolRegistry
        )
        return Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
    }

    static func makeRuntime(
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        router: RunEventRouter,
        toolRegistry: ToolRegistry
    ) -> ConversationRuntime {
        ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            onEvent: { event in
                await router.handle(event)
            },
            toolRegistry: toolRegistry
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
        confirmationReadInterceptor: @escaping ConfirmationReadInterceptor = { _, _, read in
            await read()
        },
        onTargetFailure: @escaping @MainActor @Sendable (AppTargetFailure) -> Void = { _ in }
    ) -> ComposerRuntimeActionBridge {
        let startContext = ConversationStartContext(
            conversationID: id,
            store: dependencies.store,
            provider: dependencies.provider,
            credentials: dependencies.credentials,
            runtime: dependencies.runtime,
            confirmationReadInterceptor: confirmationReadInterceptor,
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
            }
        )
    }

    private static func safeSummary(for error: Error) -> String {
        let code = (error as NSError).code
        return "\(String(reflecting: type(of: error))) (code \(code))"
    }

    static func confirmSubmission(
        _ command: SendCommand,
        expectedRunID: String?,
        in store: PersistenceStore
    ) -> ComposerSendConfirmationResult {
        do {
            guard let run = try store.run(submissionID: command.submissionID) else {
                return .noRun
            }
            guard let conversation = try store.conversation(id: command.conversationID),
                  conversation.id == command.conversationID,
                  run.kind == .parent,
                  run.parentRunID == nil,
                  run.submissionID == command.submissionID,
                  run.conversationID == command.conversationID,
                  expectedRunID == nil || expectedRunID == run.id,
                  let triggerMessageID = run.triggerMessageID,
                  let message = try store.messages(inConversation: command.conversationID)
                    .first(where: { $0.id == triggerMessageID }),
                  message.role == .user,
                  message.conversationID == command.conversationID else {
                return .inconclusive
            }

            let parts = try store.parts(ofMessage: message.id)
            guard parts.count == 1,
                  let textPart = parts.first,
                  textPart.sequence == 0,
                  textPart.kind == .text,
                  textPart.state == .completed,
                  try store.text(ofPart: textPart.id) == command.text else {
                return .inconclusive
            }

            let references = try store.quoteReferences(forMessageID: message.id)
            guard references.count == command.references.count else {
                return .inconclusive
            }
            for (sequence, pair) in zip(command.references, references).enumerated() {
                let (expected, saved) = pair
                guard saved.sequence == sequence,
                      saved.id == expected.id,
                      saved.sourceConversationID == expected.source.sourceConversationID,
                      saved.sourceMessageID == expected.source.sourceMessageID,
                      saved.sourcePartID == expected.source.sourcePartID,
                      saved.sourceUTF16Start == expected.source.range.utf16Start,
                      saved.sourceUTF16Length == expected.source.range.utf16Length,
                      saved.snapshot == expected.snapshot,
                      saved.createdAt == expected.createdAt else {
                    return .inconclusive
                }
            }

            let attachments = try store.attachments(forMessage: message.id)
            guard attachments.count == command.attachments.count else {
                return .inconclusive
            }
            for (sequence, pair) in zip(command.attachments, attachments).enumerated() {
                let (expected, saved) = pair
                guard saved.sequence == sequence,
                      saved.assetID == expected.assetID,
                      saved.versionID == expected.versionID,
                      let asset = try store.fileAsset(id: saved.assetID),
                      asset.displayName == expected.displayName,
                      let version = try store.fileAssetVersion(id: saved.versionID),
                      version.assetID == expected.assetID,
                      version.contentFingerprint == expected.fingerprint else {
                    return .inconclusive
                }
            }

            return .matchingRun(runID: run.id, state: run.state)
        } catch {
            return .inconclusive
        }
    }
}

actor ConversationStartContext {
    private let conversationID: String
    private let store: PersistenceStore
    private let provider: any ModelProvider
    private let credentials: any CredentialStoring
    private let runtime: ConversationRuntime
    private let confirmationReadInterceptor: AppAssembly.ConfirmationReadInterceptor
    private let onTargetFailure: @MainActor @Sendable (AppTargetFailure) -> Void
    private var pendingConversation: ConversationRecord?
    private var isPersisted = false

    init(
        conversationID: String,
        store: PersistenceStore,
        provider: any ModelProvider,
        credentials: any CredentialStoring,
        runtime: ConversationRuntime,
        confirmationReadInterceptor: @escaping AppAssembly.ConfirmationReadInterceptor,
        onTargetFailure: @escaping @MainActor @Sendable (AppTargetFailure) -> Void
    ) {
        self.conversationID = conversationID
        self.store = store
        self.provider = provider
        self.credentials = credentials
        self.runtime = runtime
        self.confirmationReadInterceptor = confirmationReadInterceptor
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
            await onTargetFailure(failure)
            switch failure {
            case .keyMissing:
                throw ComposerSendFailure.keyMissing
            case .keychainUnavailable:
                throw ComposerSendFailure.keychainUnavailable
            default:
                throw ComposerSendFailure.configurationUnavailable
            }
        }

        let returnedRunID: String?
        let startFailure: Error?
        do {
            returnedRunID = try await runtime.start(
                command,
                creatingConversationIfMissing: isPersisted ? nil : pendingConversation
            )
            startFailure = nil
        } catch {
            returnedRunID = nil
            startFailure = error
        }

        let startContext = self
        let read: AppAssembly.ConfirmationReadOperation = {
            await startContext.confirmSubmission(command, expectedRunID: returnedRunID)
        }
        let confirmation = await confirmationReadInterceptor(command, returnedRunID, read)
        switch confirmation {
        case .matchingRun(let runID, _):
            return runID
        case .noRun where startFailure != nil:
            throw startFailure!
        case .noRun, .inconclusive:
            let readInterceptor = confirmationReadInterceptor
            let startContext = self
            let handle = ComposerSendConfirmationHandle(
                command: command,
                runtimeStartReturnedRunID: returnedRunID,
                runtimeStartFailed: startFailure != nil,
                startFailureMessage: startFailure.map(ComposerSendFailure.safeMessage(for:))
                    ?? "发送失败，请重试。",
                read: {
                    await readInterceptor(command, returnedRunID) {
                        await startContext.confirmSubmission(
                            command,
                            expectedRunID: returnedRunID
                        )
                    }
                }
            )
            throw ComposerSendFailure.confirmationRequired(handle)
        }
    }

    private func confirmSubmission(
        _ command: SendCommand,
        expectedRunID: String?
    ) -> ComposerSendConfirmationResult {
        let result = AppAssembly.confirmSubmission(
            command,
            expectedRunID: expectedRunID,
            in: store
        )
        if case .matchingRun = result {
            isPersisted = true
            pendingConversation = nil
        }
        return result
    }
}
