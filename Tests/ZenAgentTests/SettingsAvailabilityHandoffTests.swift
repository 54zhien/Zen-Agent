import Foundation
import Testing
@testable import ZenAgent

@Suite("Settings availability handoff")
@MainActor
struct SettingsAvailabilityHandoffTests {
    @Test("reauthentication repairs the same Composer and the next Send uses its new binding")
    func reauthenticationRefreshesRetainedComposerWithoutReplacement() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none,
            scripts: [.events([.textDelta("reply"), .finish(.stop)])])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let shell = fixture.model
        await shell.launchRestorationTask?.value
        let pane = try #require(shell.pane)
        pane.composer.draft.text = "原来的中文草稿 🧑🏽‍💻"
        pane.composer.draft.selection = ComposerSelection(range: 1..<3)
        let draft = pane.composer.draft, configuration = pane.composer.configuration
        #expect(!pane.composer.sendAvailability.isReady)
        let settings = try #require(shell.makeSettingsModel())
        let instance = try #require(try fixture.store.providerInstance(id: fixture.instanceID))
        let editor = settings.accountEditor(for: instance)
        editor.apiKey = "reauth-handoff-fixture"
        await editor.reauthenticate()
        #expect(editor.errorMessage == nil)
        #expect(shell.pane === pane)
        #expect(pane.composer.draft == draft)
        #expect(pane.composer.configuration == configuration)
        #expect(pane.composer.sendAvailability.isReady)
        guard pane.composer.sendAvailability.isReady else { return }
        let bridge = try #require(shell.actionBridge)
        let coordinator = pane.session.sendCoordinator(bridge: bridge, maxProviderSteps: 4)
        _ = await coordinator.handlePrimaryAction()
        let run = try #require(try fixture.store.runs(inConversation: pane.conversationID).first)
        try await fixture.runtime.waitForCompletion(runID: run.id)
        let request = try #require((await fixture.provider.ledger.requestsSnapshot()).first)
        #expect(request.modelID == fixture.modelID)
        #expect(run.requestConfigSeed.credentialBinding.reference == editor.instance.credentialReference)
        #expect(run.requestConfigSeed.providerInstanceID == configuration?.providerInstanceID)
    }

    @Test("the account signal reaches warm and both active matching owners", arguments: ["warm", "split"])
    func reauthenticationRefreshesMatchingOwners(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let shell = fixture.model
        await shell.launchRestorationTask?.value
        let original = try #require(shell.pane?.session)
        original.composer.draft.text = "warm account draft"
        let configuration = original.composer.configuration
        if kind == "split" {
            #expect(shell.commitSplitDrop(SplitDropIntent(conversationID: shell.conversationID, slot: .top)))
            #expect(shell.createNewInSplit())
        } else { shell.newConversation() }
        let other = try #require(kind == "split" ? shell.splitPane?.session : shell.pane?.session)
        let otherConfiguration = other.composer.configuration
        let settings = try #require(shell.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.apiKey = "matching-owners-fixture"
        await editor.reauthenticate()
        #expect(original.composer.sendAvailability.isReady)
        #expect(other.composer.sendAvailability.isReady)
        #expect(original.composer.draft.text == "warm account draft")
        #expect(original.composer.configuration == configuration)
        #expect(other.composer.configuration == otherConfiguration)
    }

    @Test("a failed account save does not change the blocked owner")
    func failedSaveDoesNotRefreshAvailability() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let availability = pane.composer.sendAvailability
        let settings = try #require(fixture.model.makeSettingsModel())
        let instance = try #require(try fixture.store.providerInstance(id: fixture.instanceID))
        let editor = settings.accountEditor(for: instance)
        _ = try fixture.store.reconfigureProviderInstance(id: instance.id, displayName: "accepted edit",
            baseURL: nil, expectedEditRevision: instance.editRevision)
        editor.apiKey = "conflicting-save-fixture"
        await editor.reauthenticate()
        #expect(editor.errorMessage != nil)
        #expect(pane.composer.sendAvailability == availability)
        #expect(editor.apiKey == "conflicting-save-fixture")
    }

    @Test("configuration save does not enable an unreadable credential")
    func unreadableCredentialRemainsUnavailable() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .unreadableSecret)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let settings = try #require(fixture.model.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.endpoint = "https://edited.example.com"
        await editor.saveConfiguration()
        #expect(editor.errorMessage == nil)
        #expect(!pane.composer.sendAvailability.isReady)
    }

    @Test("credential save still validates the selected model and never configures a nil target",
          arguments: ["unsupported", "unconfigured"])
    func saveIsNotAnUnconditionalReady(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        if kind == "unsupported" {
            pane.composer.configuration?.modelID = ModelID(rawValue: "unsupported-model")
            pane.composer.sendAvailability = .checking
        } else {
            pane.composer.configuration = nil
            pane.composer.sendAvailability = .unconfigured
        }
        let configuration = pane.composer.configuration
        let settings = try #require(fixture.model.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.apiKey = "validated-target-fixture"
        await editor.reauthenticate()
        #expect(pane.composer.configuration == configuration)
        #expect(pane.composer.sendAvailability == (kind == "unsupported"
            ? .unavailable(AppTargetFailure.configurationUnavailable.message) : .unconfigured))
    }

    @Test("closing Settings cannot drop a successfully committed credential signal")
    func closingSettingsDoesNotDropTheCommittedSignal() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let settings = try #require(fixture.model.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.apiKey = "closed-settings-fixture"
        let save = Task { await editor.reauthenticate() }
        settings.invalidate()
        await save.value
        #expect(pane.composer.sendAvailability.isReady)
        #expect(fixture.model.pane === pane)
    }

    @Test("reauthentication leaves the active old Run and its execution snapshot frozen")
    func activeRunRemainsFrozen() async throws {
        let box = Stage2StreamBox()
        let fixture = try AppShellWiringTests().makeFixture(seed: .active,
            scripts: [.holding(prefix: [.textDelta("old reply")], box: box)])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let coordinator = pane.session.sendCoordinator(bridge: bridge, maxProviderSteps: 4)
        pane.composer.draft.text = "old submitted input"
        _ = await coordinator.handlePrimaryAction()
        await box.waitUntilReady()
        let id = try #require(try fixture.store.activeParentRunIDs().first)
        for _ in 0..<100 where try fixture.store.run(id: id)?.state != .streaming {
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try #require(try fixture.store.run(id: id))
        #expect(original.state == .streaming)
        pane.composer.draft.text = "next input retained"
        fixture.backend.unreadableReferences = [fixture.reference.id]
        pane.composer.sendAvailability = .unavailable(AppTargetFailure.keychainUnavailable.message)
        let settings = try #require(fixture.model.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.apiKey = "active-run-new-key-fixture"
        await editor.reauthenticate()
        let unchanged = try #require(try fixture.store.run(id: id))
        #expect(unchanged.requestConfigSeed == original.requestConfigSeed)
        #expect(unchanged.executionSnapshot == original.executionSnapshot)
        #expect(unchanged.state == original.state)
        #expect(pane.composer.sendAvailability.isReady)
        #expect(pane.composer.draft.text == "next input retained")
        try await fixture.runtime.stop(runID: id)
        try await fixture.runtime.waitForCompletion(runID: id)
    }

    @Test("late validation cannot enable a newly selected account")
    func lateValidationDoesNotOverwriteChangedConfiguration() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let store = fixture.store, instanceID = fixture.instanceID
        let gate = AvailabilityReadGate(base: fixture.backend, isPublished: { reference in
            (try? store.providerInstance(id: instanceID)?.credentialReference) == reference
        })
        let credentials = CredentialStore(secrets: gate, metadataRepository: fixture.metadata)
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(store: fixture.store, provider: fixture.provider,
            credentials: credentials, router: router, toolRegistry: .empty)
        let shell = AppShellModel(dependencies: .init(store: fixture.store, credentials: credentials,
            provider: fixture.provider, runtime: runtime, router: router), userDefaults: fixture.defaults)
        await shell.launchRestorationTask?.value
        let pane = try #require(shell.pane)
        let other = ProviderInstanceID(rawValue: "unconfigured-other-account")
        try fixture.store.createProviderInstance(ProviderInstance(id: other, providerID: .deepSeek,
            displayName: "Other", baseURL: nil, configRevision: .initial, credentialReference: nil))
        let settings = try #require(shell.makeSettingsModel())
        let editor = settings.accountEditor(for: try #require(try fixture.store.providerInstance(id: fixture.instanceID)))
        editor.apiKey = "late-validation-fixture"
        gate.arm()
        defer { gate.release() }
        let save = Task { await editor.reauthenticate() }
        for _ in 0..<250 where !gate.hasEntered { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gate.hasEntered)
        pane.composer.configuration = .init(providerInstanceID: other, modelID: fixture.modelID)
        pane.composer.sendAvailability = .unavailable(AppTargetFailure.keyMissing.message)
        gate.release()
        await save.value
        #expect(pane.composer.configuration?.providerInstanceID == other)
        #expect(pane.composer.sendAvailability == .unavailable(AppTargetFailure.keyMissing.message))
    }
}

private final class AvailabilityReadGate: SecretBackend, @unchecked Sendable {
    private let base: any SecretBackend
    private let isPublished: @Sendable (CredentialReference) -> Bool
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    init(base: any SecretBackend, isPublished: @escaping @Sendable (CredentialReference) -> Bool) {
        self.base = base; self.isPublished = isPublished
    }
    var hasEntered: Bool { lock.withLock { entered } }
    func arm() { lock.withLock { armed = true } }
    func release() { semaphore.signal() }
    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        try base.store(secret, for: reference, generation: generation)
    }
    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        if isPublished(reference), lock.withLock({
            guard armed else { return false }
            armed = false; entered = true; return true
        }) { _ = semaphore.wait(timeout: .now() + 10) }
        return try base.load(reference, generation: generation)
    }
    func delete(_ reference: CredentialReference, generation: Int) throws {
        try base.delete(reference, generation: generation)
    }
}
