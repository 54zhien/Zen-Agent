import Foundation
import Observation

struct AppExecutionTarget: Equatable, Sendable {
    let providerInstanceID: ProviderInstanceID
    let modelID: ModelID
}

enum AppShellLaunchState: Equatable {
    case notStarted
    case loading
    case ready
    case failed(AppAssemblyFailure)
}

@MainActor
@Observable
final class AppShellModel {
    static let defaultInstanceIDKey = "zen.w1.defaultTarget.v1.instanceID"
    static let defaultModelIDKey = "zen.w1.defaultTarget.v1.modelID"
    static let maxProviderSteps = 4

    private(set) var launchState: AppShellLaunchState = .notStarted
    private(set) var conversationID = UUID().uuidString
    private(set) var target: AppExecutionTarget?
    private(set) var targetMessage: String?
    private(set) var pane: ConversationPaneController?
    private(set) var actionBridge: ComposerRuntimeActionBridge?
    private(set) var composerSendCoordinator: ComposerSendCoordinator?
    private(set) var providerSetup: ProviderSetupModel?
    private(set) var router: RunEventRouter

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let confirmationReadInterceptor: AppAssembly.ConfirmationReadInterceptor
    @ObservationIgnored private var dependencies: AppAssembly.Dependencies?
    @ObservationIgnored private var startedAssembly = false

    var canSend: Bool {
        target != nil && pane != nil && actionBridge != nil
    }

    var canPresentCurrentPane: Bool {
        guard pane != nil, actionBridge != nil, dependencies?.runtime != nil else { return false }
        return canSend || composerSendCoordinator?.hasPendingConfirmation == true
    }

    var blocksConversationReplacement: Bool {
        composerSendCoordinator?.blocksConversationReplacement == true
    }

    var runtimeForPresentation: ConversationRuntime? {
        dependencies?.runtime
    }

    init(
        userDefaults: UserDefaults = .standard,
        confirmationReadInterceptor: @escaping AppAssembly.ConfirmationReadInterceptor = { _, _, read in
            await read()
        }
    ) {
        self.userDefaults = userDefaults
        self.confirmationReadInterceptor = confirmationReadInterceptor
        self.router = RunEventRouter()
    }

    init(
        dependencies: AppAssembly.Dependencies,
        userDefaults: UserDefaults,
        confirmationReadInterceptor: @escaping AppAssembly.ConfirmationReadInterceptor = { _, _, read in
            await read()
        }
    ) {
        self.userDefaults = userDefaults
        self.confirmationReadInterceptor = confirmationReadInterceptor
        self.dependencies = dependencies
        self.router = dependencies.router
        self.launchState = .ready
        self.startedAssembly = true
        prepareProviderSetup()
        loadDefaultTarget()
    }

    func assembleIfNeeded() {
        guard !startedAssembly else { return }
        assemble()
    }

    func assemble() {
        guard !blocksConversationReplacement else { return }
        startedAssembly = true
        launchState = .loading
        dependencies = nil
        pane = nil
        actionBridge = nil
        composerSendCoordinator = nil
        target = nil
        targetMessage = nil
        providerSetup = nil
        router = RunEventRouter()

        do {
            let assembled = try AppAssembly.assemble(router: router)
            dependencies = assembled
            launchState = .ready
            prepareProviderSetup()
            loadDefaultTarget()
        } catch let failure as AppAssemblyFailure {
            launchState = .failed(failure)
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
        }
    }

    func newConversation() {
        guard !blocksConversationReplacement else { return }
        router.unregisterPane(for: conversationID)
        pane = nil
        actionBridge = nil
        composerSendCoordinator = nil
        conversationID = UUID().uuidString
        installPaneIfReady()
    }

    @discardableResult
    func openConversation(id: String) -> Bool {
        guard !blocksConversationReplacement else { return false }
        guard let dependencies, let target else { return false }
        do {
            let timeline = try ConversationTimelineLoader.load(
                conversationID: id,
                from: dependencies.store
            )
            router.unregisterPane(for: conversationID)
            pane = nil
            actionBridge = nil
            composerSendCoordinator = nil
            conversationID = id
            try installPane(
                initialTimeline: timeline,
                dependencies: dependencies,
                target: target
            )
            return true
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
            return false
        }
    }

    @discardableResult
    func retryExistingTarget() -> String {
        guard let dependencies,
              let instanceRawValue = userDefaults.string(forKey: Self.defaultInstanceIDKey),
              let modelRawValue = userDefaults.string(forKey: Self.defaultModelIDKey),
              !instanceRawValue.isEmpty,
              !modelRawValue.isEmpty else {
            target = nil
            targetMessage = "尚未配置模型"
            return "尚未配置模型"
        }

        let candidate = AppExecutionTarget(
            providerInstanceID: ProviderInstanceID(rawValue: instanceRawValue),
            modelID: ModelID(rawValue: modelRawValue)
        )
        do {
            _ = try AppAssembly.validateTarget(
                providerInstanceID: candidate.providerInstanceID,
                modelID: candidate.modelID,
                store: dependencies.store,
                provider: dependencies.provider,
                credentials: dependencies.credentials
            )
            target = candidate
            targetMessage = nil
            if let pane {
                pane.composer.configuration = ConversationComposerConfiguration(
                    providerInstanceID: candidate.providerInstanceID,
                    modelID: candidate.modelID
                )
            } else {
                installPaneIfReady()
            }
            return "配置已恢复"
        } catch let failure as AppTargetFailure {
            target = nil
            targetMessage = failure.message
            return failure.message
        } catch {
            target = nil
            targetMessage = AppTargetFailure.configurationUnavailable.message
            return AppTargetFailure.configurationUnavailable.message
        }
    }

    private func prepareProviderSetup() {
        guard let dependencies else { return }
        providerSetup = ProviderSetupModel(
            store: dependencies.store,
            credentials: dependencies.credentials,
            provider: dependencies.provider,
            userDefaults: userDefaults,
            onTargetSaved: { [weak self] savedTarget in
                self?.targetWasSaved(savedTarget)
            }
        )
    }

    private func loadDefaultTarget() {
        guard let dependencies else { return }
        guard let instanceRawValue = userDefaults.string(forKey: Self.defaultInstanceIDKey),
              let modelRawValue = userDefaults.string(forKey: Self.defaultModelIDKey),
              !instanceRawValue.isEmpty,
              !modelRawValue.isEmpty else {
            target = nil
            targetMessage = "尚未配置模型"
            return
        }

        let candidate = AppExecutionTarget(
            providerInstanceID: ProviderInstanceID(rawValue: instanceRawValue),
            modelID: ModelID(rawValue: modelRawValue)
        )
        do {
            _ = try AppAssembly.validateTarget(
                providerInstanceID: candidate.providerInstanceID,
                modelID: candidate.modelID,
                store: dependencies.store,
                provider: dependencies.provider,
                credentials: dependencies.credentials
            )
            target = candidate
            targetMessage = nil
            installPaneIfReady()
        } catch let failure as AppTargetFailure {
            target = nil
            targetMessage = failure.message
        } catch {
            target = nil
            targetMessage = AppTargetFailure.configurationUnavailable.message
        }
    }

    private func targetWasSaved(_ savedTarget: AppExecutionTarget) {
        target = savedTarget
        targetMessage = nil
        guard let pane else {
            installPaneIfReady()
            return
        }
        pane.composer.configuration = ConversationComposerConfiguration(
            providerInstanceID: savedTarget.providerInstanceID,
            modelID: savedTarget.modelID
        )
    }

    private func targetBecameUnavailable(_ failure: AppTargetFailure) {
        target = nil
        targetMessage = failure.message
    }

    private func installPaneIfReady() {
        guard let dependencies, let target else { return }
        do {
            try installPane(
                initialTimeline: ConversationTimelineProjection(
                    conversationID: conversationID,
                    turns: []
                ),
                dependencies: dependencies,
                target: target
            )
        } catch {
            launchState = .failed(.wiring(summary: String(reflecting: type(of: error))))
        }
    }

    private func installPane(
        initialTimeline: ConversationTimelineProjection,
        dependencies: AppAssembly.Dependencies,
        target: AppExecutionTarget
    ) throws {
        let bridge = AppAssembly.wireConversation(
            id: conversationID,
            dependencies: dependencies,
            confirmationReadInterceptor: confirmationReadInterceptor,
            onTargetFailure: { [weak self] failure in
                self?.targetBecameUnavailable(failure)
            }
        )
        let pane = try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: initialTimeline,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: target.providerInstanceID,
                modelID: target.modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(10)),
            loadTimeline: { id in
                try ConversationTimelineLoader.load(conversationID: id, from: dependencies.store)
            }
        )
        guard dependencies.router.registerPane(pane) else {
            throw AppTargetFailure.configurationUnavailable
        }
        let coordinator = ComposerSendCoordinator(
            conversationID: conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: Self.maxProviderSteps
        )
        actionBridge = bridge
        self.pane = pane
        composerSendCoordinator = coordinator
    }
}
