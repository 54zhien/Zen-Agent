import Foundation
import Testing

@testable import ZenAgent

@Suite("W1 provider repair")
@MainActor
struct W1ProviderRepairTests {
    @Test("existingTargetRetryIsReadOnlyAndNewInstanceWritesDoNotMoveOldTarget")
    func existingTargetRetryIsReadOnlyAndNewInstanceWritesDoNotMoveOldTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let setup = try #require(fixture.model.providerSetup)
        let oldKey = "w1-old-test-key-\(UUID().uuidString)"
        setup.apiKey = oldKey
        #expect(setup.save())
        let oldTarget = try #require(fixture.model.target)
        let oldPane = try #require(fixture.model.pane)
        let oldCoordinator = try #require(fixture.model.composerSendCoordinator)
        let oldReference = setup.credentialReference
        let oldInstance = try #require(try fixture.store.providerInstance(id: oldTarget.providerInstanceID))

        let sharedInstanceID = ProviderInstanceID(rawValue: "shared-\(UUID().uuidString)")
        try fixture.store.createProviderInstance(ProviderInstance(
            id: sharedInstanceID,
            providerID: .deepSeek,
            displayName: "Shared reference instance",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: oldReference
        ))
        let sharedBefore = try #require(try fixture.store.providerInstance(id: sharedInstanceID))
        let defaultInstanceBeforeRetry = fixture.defaults.string(
            forKey: AppShellModel.defaultInstanceIDKey
        )
        let defaultModelBeforeRetry = fixture.defaults.string(
            forKey: AppShellModel.defaultModelIDKey
        )
        let storeCountBeforeRetry = fixture.backend.storeCallCount

        fixture.backend.setLoadBehavior(.missing)
        #expect(messageMatches(fixture.model.retryExistingTarget(), expected: "Key 缺失"))
        #expect(messageMatches(fixture.model.targetMessage, expected: "Key 缺失"))
        #expect(!fixture.model.canSend)

        fixture.backend.setLoadBehavior(.unavailable)
        #expect(messageMatches(fixture.model.retryExistingTarget(), expected: "Keychain 不可用"))
        #expect(messageMatches(fixture.model.targetMessage, expected: "Keychain 不可用"))

        fixture.backend.setLoadBehavior(.failed)
        #expect(messageMatches(
            fixture.model.retryExistingTarget(),
            expected: "凭据读取失败，请稍后重试"
        ))
        #expect(messageMatches(
            fixture.model.targetMessage,
            expected: "凭据读取失败，请稍后重试"
        ))
        #expect(fixture.backend.storeCallCount == storeCountBeforeRetry)

        fixture.backend.setLoadBehavior(.stored)
        #expect(messageMatches(fixture.model.retryExistingTarget(), expected: "配置已恢复"))
        #expect(fixture.model.canSend)
        #expect(fixture.model.target == oldTarget)
        #expect(fixture.model.pane === oldPane)
        #expect(fixture.model.composerSendCoordinator === oldCoordinator)
        #expect(fixture.model.pane?.composer.configuration.providerInstanceID == oldTarget.providerInstanceID)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == defaultInstanceBeforeRetry)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultModelIDKey) == defaultModelBeforeRetry)
        #expect(fixture.backend.storeCallCount == storeCountBeforeRetry)
        #expect(try fixture.store.providerInstance(id: oldTarget.providerInstanceID) == oldInstance)
        #expect(try fixture.store.providerInstance(id: sharedInstanceID) == sharedBefore)
        let oldSecretAfterRetry = try fixture.credentials.resolve(
            frozenReference: oldReference,
            generation: 1
        )
        #expect(secretMatches(oldSecretAfterRetry, expected: oldKey))

        setup.startNewAttempt()
        let newInstanceID = setup.instanceID
        let newReference = setup.credentialReference
        #expect(newInstanceID != oldTarget.providerInstanceID)
        #expect(newReference != oldReference)
        let defaultInstanceBeforeWriteFailures = fixture.defaults.string(
            forKey: AppShellModel.defaultInstanceIDKey
        )
        let defaultModelBeforeWriteFailures = fixture.defaults.string(
            forKey: AppShellModel.defaultModelIDKey
        )
        let oldTargetBeforeWriteFailures = fixture.model.target
        let unavailableKey = "w1-unavailable-write-key-\(UUID().uuidString)"
        fixture.backend.setStoreBehavior(.unavailable)
        setup.apiKey = unavailableKey
        #expect(!setup.save())
        #expect(setup.state == .incomplete)
        #expect(messageMatches(
            setup.errorMessage,
            expected: "Keychain 暂不可用，请稍后重试"
        ))
        #expect(setup.apiKey.isEmpty)
        #expect(!messageContains(setup.errorMessage, needle: unavailableKey))
        #expect(!messageContains(setup.errorMessage, needle: "backend diagnostic"))
        #expect(setup.instanceID == newInstanceID)
        #expect(setup.credentialReference == newReference)
        #expect(fixture.model.target == oldTargetBeforeWriteFailures)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == defaultInstanceBeforeWriteFailures)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultModelIDKey) == defaultModelBeforeWriteFailures)
        #expect(try fixture.store.providerInstance(id: oldTarget.providerInstanceID) == oldInstance)
        #expect(try fixture.store.providerInstance(id: sharedInstanceID) == sharedBefore)
        #expect(try fixture.credentials.resolve(
            frozenReference: oldReference,
            generation: 1
        )?.revealed == oldKey)

        let failedKey = "w1-failed-write-key-\(UUID().uuidString)"
        fixture.backend.setStoreBehavior(.failed)
        setup.apiKey = failedKey
        #expect(!setup.save())
        #expect(messageMatches(setup.errorMessage, expected: "凭据存储失败"))
        #expect(setup.apiKey.isEmpty)
        #expect(!messageContains(setup.errorMessage, needle: failedKey))
        #expect(setup.instanceID == newInstanceID)
        #expect(setup.credentialReference == newReference)
        #expect(fixture.model.target == oldTargetBeforeWriteFailures)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == defaultInstanceBeforeWriteFailures)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultModelIDKey) == defaultModelBeforeWriteFailures)

        let newKey = "w1-new-test-key-\(UUID().uuidString)"
        fixture.backend.setStoreBehavior(.succeeds)
        setup.apiKey = newKey
        #expect(setup.save())
        #expect(setup.apiKey.isEmpty)
        #expect(setup.isComplete)
        #expect(setup.instanceID == newInstanceID)
        #expect(setup.credentialReference == newReference)
        #expect(fixture.model.target == AppExecutionTarget(
            providerInstanceID: newInstanceID,
            modelID: Stage2GateFixture.modelID
        ))
        #expect(fixture.model.pane === oldPane)
        #expect(fixture.model.composerSendCoordinator === oldCoordinator)
        #expect(fixture.model.pane?.composer.configuration.providerInstanceID == newInstanceID)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == newInstanceID.rawValue)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultModelIDKey) == Stage2GateFixture.modelID.rawValue)
        #expect(try fixture.store.providerInstance(id: oldTarget.providerInstanceID) == oldInstance)
        #expect(try fixture.store.providerInstance(id: sharedInstanceID) == sharedBefore)
        let oldSecretAfterWriteFailures = try fixture.credentials.resolve(
            frozenReference: oldReference,
            generation: 1
        )
        let newSecret = try fixture.credentials.resolve(
            frozenReference: newReference,
            generation: 1
        )
        #expect(secretMatches(oldSecretAfterWriteFailures, expected: oldKey))
        #expect(secretMatches(newSecret, expected: newKey))
    }

    @Test("freshSetupAfterRelaunchNeverClaimsDefaultInstanceOrReference")
    func freshSetupAfterRelaunchNeverClaimsDefaultInstanceOrReference() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let originalSetup = try #require(fixture.model.providerSetup)
        originalSetup.apiKey = "w1-relaunch-old-key-\(UUID().uuidString)"
        #expect(originalSetup.save())
        let oldID = originalSetup.instanceID
        let oldReference = originalSetup.credentialReference
        let oldInstance = try #require(try fixture.store.providerInstance(id: oldID))

        let relaunchedModel = AppShellModel(
            dependencies: fixture.dependencies,
            userDefaults: fixture.defaults
        )
        let freshSetup = try #require(relaunchedModel.providerSetup)
        #expect(freshSetup.instanceID != oldID)
        #expect(freshSetup.credentialReference != oldReference)
        freshSetup.apiKey = "w1-relaunch-new-key-\(UUID().uuidString)"
        #expect(freshSetup.save())
        #expect(freshSetup.instanceID != oldID)
        #expect(freshSetup.credentialReference != oldReference)
        #expect(relaunchedModel.target?.providerInstanceID == freshSetup.instanceID)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == freshSetup.instanceID.rawValue)
        #expect(try fixture.store.providerInstance(id: oldID) == oldInstance)
        #expect(try fixture.store.providerInstance(id: oldID)?.credentialReference == oldReference)
        #expect(try fixture.credentials.metadata(for: oldReference)?.reference == oldReference)
    }

    private func makeFixture() throws -> ProviderRepairFixture {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = W1RepairSecretBackend()
        let credentials = CredentialStore(secrets: backend, metadataRepository: store)
        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([])]
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.W1ProviderRepair.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = AppShellModel(dependencies: dependencies, userDefaults: defaults)
        return ProviderRepairFixture(
            store: store,
            backend: backend,
            credentials: credentials,
            provider: provider,
            dependencies: dependencies,
            defaults: defaults,
            defaultsSuite: suite,
            model: model
        )
    }
}

private struct ProviderRepairFixture {
    let store: PersistenceStore
    let backend: W1RepairSecretBackend
    let credentials: CredentialStore
    let provider: Stage2ScriptedProvider
    let dependencies: AppAssembly.Dependencies
    let defaults: UserDefaults
    let defaultsSuite: String
    let model: AppShellModel
}

private func secretMatches(_ secret: SecretValue?, expected: String) -> Bool {
    secret?.revealed == expected
}

private func messageMatches(_ message: String?, expected: String) -> Bool {
    message == expected
}

private func messageContains(_ message: String?, needle: String) -> Bool {
    message?.contains(needle) == true
}

private final class W1RepairSecretBackend: SecretBackend, @unchecked Sendable {
    enum LoadBehavior {
        case stored
        case missing
        case unavailable
        case failed
    }

    enum StoreBehavior {
        case succeeds
        case unavailable
        case failed
    }

    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var loadBehavior: LoadBehavior = .stored
    private var storeBehavior: StoreBehavior = .succeeds
    private var stores = 0

    var storeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stores
    }

    func setLoadBehavior(_ behavior: LoadBehavior) {
        lock.lock(); defer { lock.unlock() }
        loadBehavior = behavior
    }

    func setStoreBehavior(_ behavior: StoreBehavior) {
        lock.lock(); defer { lock.unlock() }
        storeBehavior = behavior
    }

    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        stores += 1
        switch storeBehavior {
        case .succeeds:
            secrets[key(reference, generation)] = secret.revealed
        case .unavailable:
            throw SecretBackendError.unavailable("backend diagnostic unavailable")
        case .failed:
            throw SecretBackendError.failed("backend diagnostic failed")
        }
    }

    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        lock.lock(); defer { lock.unlock() }
        switch loadBehavior {
        case .stored:
            return secrets[key(reference, generation)].map(SecretValue.init)
        case .missing:
            return nil
        case .unavailable:
            throw SecretBackendError.unavailable("backend diagnostic unavailable")
        case .failed:
            throw SecretBackendError.failed("backend diagnostic failed")
        }
    }

    func delete(_ reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: key(reference, generation))
    }

    private func key(_ reference: CredentialReference, _ generation: Int) -> String {
        "\(reference.id)#\(generation)"
    }
}
