import Foundation
import Testing
@testable import ZenAgent

@Suite("Persisted empty Configure")
@MainActor
struct PersistedEmptyConfigureTests {
    @Test("App Space durable empty returns through formal Configure and freezes its first Send choice")
    func persistedEmptyConversationConfiguresThroughFormalSettingsAndSurvivesReopen() async throws {
        let path = try Fixtures.scratchPath(name: "formal-configure.sqlite")
        defer { Fixtures.cleanUp(path) }
        let context: (id: String, binding: ConversationInitialBinding, seed: RequestConfigSeed,
            credentials: CredentialStore, provider: Stage2ScriptedProvider, defaults: UserDefaults, suite: String)
        do {
            let fixture = try AppShellWiringTests().makeFixture(seed: .none, createInstance: false,
                setDefault: false, scripts: [.events([.textDelta("reply"), .finish(.stop)])],
                store: PersistenceStore(database: try ZenDatabase.open(at: path.path())))
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
            await fixture.model.launchRestorationTask?.value
            try fixture.store.createSoul(initialVersion: SoulVersionRecord(id: "configure-soul",
                instructions: "original soul", createdAt: Fixtures.epoch), at: Fixtures.epoch)
            let id = try await createAndReturn(fixture)
            let pane = try #require(fixture.model.pane)
            pane.composer.draft.text = "未发送的配置草稿 🧑🏽‍💻"
            pane.composer.draft.selection = ComposerSelection(range: 1..<3)
            let draft = pane.composer.draft
            #expect(fixture.model.currentSettingsNewID == id)
            let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
            let setup = try #require(settings.makeProviderSetup())
            setup.apiKey = "formal-configure-fixture-key"
            setup.selectedModelID = fixture.modelID
            #expect(setup.save())
            let binding = ConversationInitialBinding(providerInstanceID: setup.instanceID, modelID: fixture.modelID)
            #expect(fixture.model.pane === pane && pane.composer.draft == draft)
            #expect(pane.composer.configuration?.providerInstanceID == setup.instanceID)
            #expect(try fixture.store.conversationInitialBinding(id: id) == binding)
            #expect(try fixture.store.conversation(id: id)?.userActiveAt == Fixtures.epoch)
            #expect(try fixture.store.boundSoulVersion(conversationID: id)?.id == "configure-soul")
            guard pane.composer.sendAvailability.isReady else { return }
            let bridge = try #require(fixture.model.actionBridge)
            _ = await pane.session.sendCoordinator(bridge: bridge, maxProviderSteps: 4).handlePrimaryAction()
            let run = try #require(try fixture.store.runs(inConversation: id).first)
            try await fixture.runtime.waitForCompletion(runID: run.id)
            #expect(run.requestConfigSeed.providerInstanceID == setup.instanceID)
            #expect(run.requestConfigSeed.modelID == fixture.modelID)
            context = (id, binding, run.requestConfigSeed, fixture.credentials, fixture.provider,
                fixture.defaults, fixture.defaultsSuite)
        }
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        // Release the original shell/runtime/store before opening a fresh connection.
        let reopenedStore = PersistenceStore(database: try ZenDatabase.open(at: path.path()))
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(store: reopenedStore, provider: context.provider,
            credentials: context.credentials, router: router, toolRegistry: .empty)
        context.defaults.set("later-global-account", forKey: AppShellModel.defaultInstanceIDKey)
        context.defaults.set(context.seed.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
        let reopened = AppShellModel(dependencies: .init(store: reopenedStore, credentials: context.credentials,
            provider: context.provider, runtime: runtime, router: router), userDefaults: context.defaults)
        await reopened.launchRestorationTask?.value
        #expect(await reopened.openConversation(id: context.id))
        #expect(reopened.pane?.composer.configuration?.providerInstanceID == context.binding.providerInstanceID)
        #expect(try reopenedStore.conversationInitialBinding(id: context.id) == context.binding)
        #expect(try reopenedStore.runs(inConversation: context.id).first?.requestConfigSeed == context.seed)
    }

    @Test("ordinary Settings default never initializes a durable empty owner")
    func ordinaryDefaultLeavesPersistedEmptyUnconfigured() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let pane = try #require(fixture.model.pane)
        let settings = try #require(fixture.model.makeSettingsModel())
        #expect(await settings.setDefault(providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        #expect(fixture.model.pane === pane && pane.composer.configuration == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id) == .init())
    }

    @Test("a captured Configure cannot initialize a replacement owner")
    func newDuringConfigureKeepsCapturedBindingEmpty() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        let setup = try #require(settings.makeProviderSetup())
        fixture.model.newConversation()
        let replacement = try #require(fixture.model.pane)
        setup.apiKey = "stale-formal-configure-fixture"
        #expect(setup.save())
        #expect(replacement.composer.configuration == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id) == .init())
    }

    @Test("write rejection keeps the nil Composer and exposes feedback after catalog reload", arguments: ["throw", "reject"])
    func failedBindingWriteDoesNotOnlyConfigureTheUI(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        let setup = try #require(settings.makeProviderSetup())
        try fixture.store.database.write { db in
            if kind == "throw" {
                try db.execute(sql: "CREATE TRIGGER configure_write_failure BEFORE UPDATE ON conversationInitialBinding BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
            } else {
                try db.execute(sql: "CREATE TRIGGER configure_write_rejection BEFORE UPDATE ON conversationInitialBinding BEGIN SELECT RAISE(IGNORE); END")
            }
        }
        setup.apiKey = "failed-binding-fixture"
        #expect(setup.save())
        #expect(fixture.model.pane?.composer.configuration == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id) == .init())
        #expect(settings.errorMessage != nil)
        await settings.load()
        #expect(settings.errorMessage != nil)
    }

    @Test("delete, competing initialization and first Send prevent late binding commits", arguments: ["delete", "secondConfigure", "firstSend"])
    func competingCommitNeverRetargetsTheComposer(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        let setup = try #require(settings.makeProviderSetup())
        if kind == "delete" { try fixture.store.beginDeletion(conversationID: id) }
        else if kind == "secondConfigure" {
            #expect(try fixture.store.initializeEmptyConversationBinding(id: id,
                binding: .init(providerInstanceID: fixture.instanceID, modelID: fixture.modelID), at: Fixtures.epoch))
        } else {
            try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: id,
                messageID: "competing-first-send", runID: "competing-first-run", runState: .completed))
        }
        let binding = try fixture.store.conversationInitialBinding(id: id)
        setup.apiKey = "competing-binding-fixture"
        #expect(setup.save())
        #expect(fixture.model.pane?.composer.configuration == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id) == binding)
        #expect(settings.errorMessage != nil)
    }

    @Test("copied configuration and published history do not advertise initialization")
    func copiedBindingAndHistoryHaveNoConfigureEntry() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        #expect(fixture.model.currentSettingsNewID == nil)
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: id,
            messageID: "existing-message", runID: "existing-run", runState: .completed))
        #expect(fixture.model.currentSettingsNewID == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id)?.providerInstanceID == fixture.instanceID)
    }

    @Test("existing account configures only the captured owner without choosing a future default")
    func existingAccountWithoutDefaultUsesExplicitCapturedSelection() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let pane = try #require(fixture.model.pane)
        pane.composer.draft.text = "现有账户的草稿"
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        #expect(settings.isConfigureMode)
        #expect(await settings.configureCapturedConversation(providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        #expect(fixture.model.pane === pane && pane.composer.draft.text == "现有账户的草稿")
        #expect(pane.composer.configuration?.providerInstanceID == fixture.instanceID)
        #expect(try fixture.store.conversationInitialBinding(id: id) == ConversationInitialBinding(
            providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        #expect(settings.defaultTarget == nil)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == nil)
        #expect(await settings.configureCapturedConversation(providerInstanceID: fixture.instanceID, modelID: fixture.modelID) == false)
        #expect(settings.errorMessage != nil)
        fixture.model.newConversation()
        #expect(fixture.model.pane?.composer.configuration == nil)
    }

    @Test("unsupported and unreadable targets leave durable binding and Composer empty", arguments: ["unsupported", "unreadable"])
    func invalidTargetDoesNotInitialize(kind: String) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        if kind == "unreadable" { fixture.backend.unreadableReferences = [fixture.reference.id] }
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        #expect(await settings.configureCapturedConversation(providerInstanceID: fixture.instanceID,
            modelID: kind == "unsupported" ? .init(rawValue: "unsupported") : fixture.modelID) == false)
        #expect(fixture.model.pane?.composer.configuration == nil)
        #expect(try fixture.store.conversationInitialBinding(id: id) == ConversationInitialBinding())
        #expect(settings.errorMessage != nil)
    }

    @Test("unreadable binding storage hides entry and cannot initialize UI through a captured Settings model")
    func readFailureDoesNotGrantInitialization() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        try fixture.store.database.write { db in
            try db.execute(sql: "ALTER TABLE conversationInitialBinding RENAME TO unavailable_binding")
        }
        #expect(fixture.model.currentSettingsNewID == nil)
        #expect(throws: (any Error).self) { try fixture.model.configurationOwner(id: id) }
        #expect(await settings.configureCapturedConversation(providerInstanceID: fixture.instanceID, modelID: fixture.modelID) == false)
        #expect(fixture.model.pane?.composer.configuration == nil)
        #expect(settings.errorMessage != nil)
        await settings.load()
        #expect(settings.errorMessage != nil)
    }

    @Test("atomic read eligibility requires visible empty content and a present empty binding row",
        arguments: ["empty", "copied", "history", "deleted", "missingRow", "missing"])
    func persistedReadEligibilityMatchesInitializationConstraints(kind: String) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        if kind != "missing" {
            try store.createEmptyConversation(id: "eligibility", at: Fixtures.epoch,
                initialBinding: kind == "copied" ? .init(providerInstanceID: .init(rawValue: "copied"),
                    modelID: .init(rawValue: "copied-model")) : .init())
        }
        if kind == "history" {
            try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "eligibility",
                messageID: "eligibility-message", runID: "eligibility-run", runState: .completed))
        } else if kind == "deleted" { try store.beginDeletion(conversationID: "eligibility") }
        else if kind == "missingRow" {
            try store.database.write { db in
                try db.execute(sql: "DELETE FROM conversationInitialBinding WHERE conversationID = 'eligibility'")
            }
        }
        #expect(try store.canInitializeEmptyConversationBinding(id: "eligibility") == (kind == "empty"))
    }

    private func createAndReturn(_ fixture: ShellFixture) async throws -> String {
        await fixture.model.launchRestorationTask?.value
        #expect(fixture.model.enterPreview())
        let id = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(await fixture.model.preparePreviewReturn(to: id))
        #expect(fixture.model.commitPreviewReturn())
        return id
    }
}
