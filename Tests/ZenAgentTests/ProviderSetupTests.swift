import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Provider setup continuation")
@MainActor
struct ProviderSetupTests {
    @Test("completedConfigurationKeepsKeyOutOfDatabaseAndDefaults")
    func completedConfigurationKeepsKeyOutOfDatabaseAndDefaults() throws {
        try withFileEnvironment { environment, databaseURL -> Void in
            let setup = environment.makeSetup()
            let reference = setup.credentialReference
            let instanceID = setup.instanceID
            let key = "provider-setup-scan-key-\(UUID().uuidString)"
            setup.apiKey = key

            #expect(setup.save())
            #expect(setup.apiKey.isEmpty)
            #expect(setup.isComplete)
            #expect(setup.errorMessage == nil)
            #expect(setup.errorMessage?.contains(key) != true)
            #expect(setup.statusLabel == "配置完成")
            #expect(try environment.store.providerInstance(id: instanceID)?.credentialReference == reference)
            #expect(try environment.credentials.metadata(for: reference)?.status == .active)
            #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == key)

            let instance = try #require(try environment.store.providerInstance(id: instanceID))
            let descriptor = try #require(environment.provider.knownModels(for: instance).first {
                $0.id == setup.selectedModelID
            })
            let metadata = try #require(try environment.credentials.metadata(for: reference))
            let resolved = try #require(try environment.credentials.resolve(
                frozenReference: metadata.reference,
                generation: metadata.bindingGeneration
            ))
            #expect(descriptor.providerInstanceID == instance.id)
            #expect(descriptor.capabilities.contains(.text))
            #expect(descriptor.capabilities.contains(.streaming))
            #expect(resolved.revealed == key)
            #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == instanceID.rawValue)
            #expect(environment.defaults.string(forKey: AppShellModel.defaultModelIDKey) == setup.selectedModelID?.rawValue)
            #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) != key)
            #expect(environment.defaults.string(forKey: AppShellModel.defaultModelIDKey) != key)

            let storedFields = try environment.store.database.read { db -> [String] in
                let instanceValue = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM providerInstance WHERE id = ?",
                    arguments: [instanceID.rawValue]
                )
                let metadataValue = try String.fetchOne(
                    db,
                    sql: "SELECT credentialID FROM credentialBinding WHERE credentialID = ?",
                    arguments: [reference.id]
                )
                return [instanceValue, metadataValue].compactMap { $0 }
            }
            #expect(storedFields.contains(instanceID.rawValue))
            #expect(storedFields.contains(reference.id))
            #expect(!storedFields.joined(separator: "\n").contains(key))

            let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
            var filesToScan = [databaseURL]
            if FileManager.default.fileExists(atPath: walURL.path) {
                filesToScan.append(walURL)
            }
            #expect(FileManager.default.fileExists(atPath: databaseURL.path))
            #expect(!filesToScan.isEmpty)
            let keyBytes = Data(key.utf8)
            for file in filesToScan {
                let bytes = try Data(contentsOf: file)
                #expect(bytes.range(of: keyBytes) == nil)
            }
        }
    }

    @Test("metadataWithMissingSecretIsRepairedWithRefresh")
    func metadataWithMissingSecretIsRepairedWithRefresh() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let setup = environment.makeSetup()
        let reference = setup.credentialReference
        let metadataRepository = try #require(environment.metadataRepository)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: 3,
            principalFingerprint: nil,
            status: .active,
            updatedAt: Date()
        ))
        let key = "provider-setup-refresh-key-\(UUID().uuidString)"
        setup.apiKey = key

        #expect(setup.save())
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 3) == key)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == nil)
        #expect(try environment.credentials.metadata(for: reference)?.bindingGeneration == 3)
        #expect(setup.state == .complete)
    }

    @Test("metadataWriteFailureRetainsSecretAndResumesSameAttempt")
    func metadataWriteFailureRetainsSecretAndResumesSameAttempt() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let setup = environment.makeSetup()
        let instanceID = setup.instanceID
        let reference = setup.credentialReference
        let key = "provider-setup-metadata-failure-key-\(UUID().uuidString)"
        let metadataRepository = try #require(environment.metadataRepository)
        metadataRepository.failNextSave = true
        setup.apiKey = key

        #expect(!setup.save())
        #expect(setup.state == .incomplete)
        #expect(setup.statusLabel == "未完成配置")
        #expect(setup.errorMessage != nil)
        #expect(setup.errorMessage?.contains(key) != true)
        #expect(!setup.isComplete)
        #expect(setup.didCreateInstance)
        #expect(setup.instanceID == instanceID)
        #expect(setup.credentialReference == reference)
        #expect(try environment.store.providerInstance(id: instanceID) != nil)
        #expect(try environment.credentials.metadata(for: reference) == nil)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == key)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        setup.apiKey = key
        #expect(setup.save())
        #expect(setup.instanceID == instanceID)
        #expect(setup.credentialReference == reference)
        #expect(setup.didCreateInstance)
        #expect(setup.didAttachCredential)
        #expect(setup.isComplete)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == key)
        #expect(makeShell(environment).canSend)
    }

    @Test("attachEditConflictResumesWithLatestRevision")
    func attachEditConflictResumesWithLatestRevision() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        var moveRevisionOnce = true
        let setup = environment.makeSetup(afterAttachSnapshot: { instance -> Void in
            guard moveRevisionOnce else { return }
            moveRevisionOnce = false
            do {
                _ = try environment.store.attachCredential(
                    nil,
                    toInstance: instance.id,
                    expectedEditRevision: instance.editRevision
                )
            } catch {
                Issue.record("injected edit should succeed")
            }
        })
        let key = "provider-setup-attach-conflict-key-\(UUID().uuidString)"
        setup.apiKey = key

        #expect(!setup.save())
        let conflicted = try #require(try environment.store.providerInstance(id: setup.instanceID))
        #expect(setup.state == .incomplete)
        #expect(setup.errorMessage == ProviderSetupFailure.editConflict.message)
        #expect(!setup.didAttachCredential)
        #expect(conflicted.credentialReference == nil)
        #expect(conflicted.editRevision.rawValue == 1)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        #expect(setup.save())
        let attached = try #require(try environment.store.providerInstance(id: setup.instanceID))
        #expect(attached.credentialReference == setup.credentialReference)
        #expect(attached.editRevision.rawValue == 2)
        #expect(setup.didAttachCredential)
        #expect(setup.isComplete)
        #expect(makeShell(environment).canSend)
    }

    @Test("modelValidationFailureKeepsInstanceUnsendableUntilCorrected")
    func modelValidationFailureKeepsInstanceUnsendableUntilCorrected() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let setup = environment.makeSetup()
        let instanceID = setup.instanceID
        let reference = setup.credentialReference
        let key = "provider-setup-model-failure-key-\(UUID().uuidString)"
        setup.selectedModelID = ModelID(rawValue: "not-in-provider-catalog")
        setup.apiKey = key

        #expect(!setup.save())
        #expect(setup.state == .incomplete)
        #expect(setup.errorMessage == ProviderSetupFailure.modelUnavailable.message)
        #expect(setup.didCreateInstance)
        #expect(setup.didAttachCredential)
        #expect(try environment.store.providerInstance(id: instanceID)?.credentialReference == reference)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == key)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        setup.selectedModelID = Stage2GateFixture.modelID
        #expect(setup.save())
        #expect(setup.instanceID == instanceID)
        #expect(setup.credentialReference == reference)
        #expect(setup.isComplete)
        #expect(makeShell(environment).canSend)
    }

    @Test("concurrentEditDuringRetryIsNotOverwritten")
    func concurrentEditDuringRetryIsNotOverwritten() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        var injectedChangesRemaining = 2
        let setup = environment.makeSetup(afterAttachSnapshot: { instance -> Void in
            guard injectedChangesRemaining > 0 else { return }
            injectedChangesRemaining -= 1
            do {
                _ = try environment.store.attachCredential(
                    nil,
                    toInstance: instance.id,
                    expectedEditRevision: instance.editRevision
                )
            } catch {
                Issue.record("injected edit should succeed")
            }
        })
        let key = "provider-setup-retry-conflict-key-\(UUID().uuidString)"
        setup.apiKey = key

        #expect(!setup.save())
        #expect(setup.errorMessage == ProviderSetupFailure.editConflict.message)
        let firstRevision = try #require(try environment.store.providerInstance(id: setup.instanceID))
            .editRevision
        #expect(firstRevision.rawValue == 1)

        #expect(!setup.save())
        let concurrentRevision = try #require(try environment.store.providerInstance(id: setup.instanceID))
            .editRevision
        #expect(setup.state == .incomplete)
        #expect(setup.errorMessage == ProviderSetupFailure.editConflict.message)
        #expect(concurrentRevision.rawValue == 2)
        #expect(try environment.store.providerInstance(id: setup.instanceID)?.credentialReference == nil)
        #expect(!setup.isComplete)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        #expect(setup.save())
        #expect(setup.isComplete)
        #expect(try environment.store.providerInstance(id: setup.instanceID)?.credentialReference == setup.credentialReference)
        #expect(makeShell(environment).canSend)
    }

    @Test("createFailureRetainsIdentifiersAndRetriesOriginalInstanceID")
    func createFailureRetainsIdentifiersAndRetriesOriginalInstanceID() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let setup = environment.makeSetup()
        let instanceID = setup.instanceID
        let reference = setup.credentialReference
        let key = "provider-setup-create-failure-key-\(UUID().uuidString)"
        try environment.store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER zen_w1_fail_instance_insert
                BEFORE INSERT ON providerInstance
                BEGIN
                    SELECT RAISE(ABORT, 'W1 injected instance insert failure');
                END
                """)
        }
        setup.apiKey = key

        #expect(!setup.save())
        #expect(setup.state == .incomplete)
        #expect(setup.statusLabel == "未完成配置")
        #expect(setup.errorMessage != nil)
        #expect(!setup.didCreateInstance)
        #expect(setup.instanceID == instanceID)
        #expect(setup.credentialReference == reference)
        #expect(try environment.store.providerInstance(id: instanceID) == nil)
        #expect(try environment.credentials.metadata(for: reference) == nil)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == nil)
        #expect(!makeShell(environment).canSend)

        try environment.store.database.write { db in
            try db.execute(sql: "DROP TRIGGER zen_w1_fail_instance_insert")
        }
        setup.apiKey = key
        #expect(setup.save())
        #expect(setup.didCreateInstance)
        #expect(setup.instanceID == instanceID)
        #expect(setup.credentialReference == reference)
        #expect(try environment.store.providerInstance(id: instanceID)?.credentialReference == reference)
        #expect(setup.isComplete)
        #expect(makeShell(environment).canSend)
    }

    @Test("existingInstanceWithoutCreationRecordIsAnUnmodifiedConflict")
    func existingInstanceWithoutCreationRecordIsAnUnmodifiedConflict() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let setup = environment.makeSetup()
        let instanceID = setup.instanceID
        let reference = setup.credentialReference
        let key = "provider-setup-collision-key-\(UUID().uuidString)"
        try environment.store.createProviderInstance(ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "Pre-existing DeepSeek",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: nil
        ))
        let before = try #require(try environment.store.providerInstance(id: instanceID))
        setup.apiKey = key

        #expect(!setup.save())
        let after = try #require(try environment.store.providerInstance(id: instanceID))
        #expect(setup.state == .identifierConflict)
        #expect(setup.statusLabel == "实例 ID 冲突")
        #expect(setup.errorMessage == ProviderSetupFailure.instanceConflict.message)
        #expect(!setup.didCreateInstance)
        #expect(after == before)
        #expect(try environment.credentials.metadata(for: reference) == nil)
        #expect(environment.secretBackend.storedSecret(for: reference, generation: 1) == nil)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        setup.startNewAttempt()
        #expect(setup.instanceID != instanceID)
        #expect(setup.credentialReference != reference)
        #expect(try environment.store.providerInstance(id: instanceID) == before)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
    }

    @Test("changedInstanceOffersNewAttemptWithoutRewritingItsReference")
    func changedInstanceOffersNewAttemptWithoutRewritingItsReference() throws {
        let environment = try makeEnvironment()
        defer { environment.defaults.removePersistentDomain(forName: environment.defaultsSuite) }
        let externalReference = CredentialReference(
            id: "external-reference-\(UUID().uuidString)",
            kind: .apiKey
        )
        let setup = environment.makeSetup(afterAttachSnapshot: { instance -> Void in
            do {
                _ = try environment.store.attachCredential(
                    externalReference,
                    toInstance: instance.id,
                    expectedEditRevision: instance.editRevision
                )
            } catch {
                Issue.record("injected reference change should succeed")
            }
        })
        setup.apiKey = "changed-instance-key-\(UUID().uuidString)"

        #expect(!setup.save())
        #expect(setup.errorMessage == ProviderSetupFailure.editConflict.message)
        #expect(!setup.save())
        #expect(setup.state == .incomplete)
        #expect(setup.errorMessage == ProviderSetupFailure.instanceChanged.message)
        #expect(setup.canAbandonAndCreateNew)
        #expect(try environment.store.providerInstance(id: setup.instanceID)?.credentialReference == externalReference)
        #expect(!setup.isComplete)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(!makeShell(environment).canSend)

        let originalID = setup.instanceID
        setup.startNewAttempt()
        #expect(setup.instanceID != originalID)
        #expect(try environment.store.providerInstance(id: originalID)?.credentialReference == externalReference)
        #expect(environment.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
    }

    private func makeEnvironment(provider: (any ModelProvider)? = nil) throws -> ProviderSetupEnvironment {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let secretBackend = InMemorySecretBackend()
        let metadataRepository = InMemoryCredentialMetadataRepository()
        let credentials = CredentialStore(
            secrets: secretBackend,
            metadataRepository: metadataRepository
        )
        let resolvedProvider = provider ?? Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([])]
        )
        let suite = "ZenAgentTests.ProviderSetup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return ProviderSetupEnvironment(
            store: store,
            secretBackend: secretBackend,
            metadataRepository: metadataRepository,
            credentials: credentials,
            provider: resolvedProvider,
            defaults: defaults,
            defaultsSuite: suite
        )
    }

    private func makeShell(_ environment: ProviderSetupEnvironment) -> AppShellModel {
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: environment.store,
            provider: environment.provider,
            credentials: environment.credentials,
            router: router,
            toolRegistry: .empty
        )
        return AppShellModel(
            dependencies: AppAssembly.Dependencies(
                store: environment.store,
                credentials: environment.credentials,
                provider: environment.provider,
                runtime: runtime,
                router: router
            ),
            userDefaults: environment.defaults
        )
    }

    private func withFileEnvironment<Value>(
        _ body: @MainActor (ProviderSetupEnvironment, URL) throws -> Value
    ) throws -> Value {
        let databaseURL = try Fixtures.scratchPath(name: "provider-setup.sqlite")
        let suite = "ZenAgentTests.ProviderSetup.File.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var database: ZenDatabase?
        var store: PersistenceStore?
        var credentials: CredentialStore?
        let secretBackend = InMemorySecretBackend()
        var result: Result<Value, Error>?

        do {
            database = try ZenDatabase.open(at: databaseURL.path)
            store = PersistenceStore(database: try #require(database))
            credentials = CredentialStore(
                secrets: secretBackend,
                metadataRepository: try #require(store)
            )
            let provider = Stage2ScriptedProvider(
                ledger: Stage2ProviderLedger(),
                scripts: [.events([])]
            )
            let environment = ProviderSetupEnvironment(
                store: try #require(store),
                secretBackend: secretBackend,
                metadataRepository: nil,
                credentials: try #require(credentials),
                provider: provider,
                defaults: defaults,
                defaultsSuite: suite
            )
            result = .success(try body(environment, databaseURL))
        } catch {
            result = .failure(error)
        }

        credentials = nil
        store = nil
        database = nil
        Fixtures.cleanUp(databaseURL)
        defaults.removePersistentDomain(forName: suite)
        guard let result else { throw ProviderSetupFailure.persistenceUnavailable }
        return try result.get()
    }
}

@MainActor
private struct ProviderSetupEnvironment {
    let store: PersistenceStore
    let secretBackend: InMemorySecretBackend
    let metadataRepository: InMemoryCredentialMetadataRepository?
    let credentials: CredentialStore
    let provider: any ModelProvider
    let defaults: UserDefaults
    let defaultsSuite: String

    func makeSetup(
        afterAttachSnapshot: (@MainActor (ProviderInstance) -> Void)? = nil
    ) -> ProviderSetupModel {
        ProviderSetupModel(
            store: store,
            credentials: credentials,
            provider: provider,
            userDefaults: defaults,
            afterAttachSnapshot: afterAttachSnapshot
        )
    }
}
