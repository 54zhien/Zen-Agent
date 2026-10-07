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
        let reopenedStore = PersistenceStore(database: try ZenDatabase.open(at: path.path()))
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(store: reopenedStore, provider: fixture.provider,
            credentials: fixture.credentials, router: router, toolRegistry: .empty)
        fixture.defaults.set("later-global-account", forKey: AppShellModel.defaultInstanceIDKey)
        let reopened = AppShellModel(dependencies: .init(store: reopenedStore, credentials: fixture.credentials,
            provider: fixture.provider, runtime: runtime, router: router), userDefaults: fixture.defaults)
        await reopened.launchRestorationTask?.value
        #expect(await reopened.openConversation(id: id))
        #expect(reopened.pane?.composer.configuration?.providerInstanceID == setup.instanceID)
        #expect(try reopenedStore.conversationInitialBinding(id: id) == binding)
        #expect(try reopenedStore.runs(inConversation: id).first?.requestConfigSeed == run.requestConfigSeed)
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

    @Test("write rejection keeps the nil Composer and exposes feedback after catalog reload")
    func failedBindingWriteDoesNotOnlyConfigureTheUI() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = try await createAndReturn(fixture)
        let settings = try #require(fixture.model.makeSettingsModel(configureNewID: id))
        let setup = try #require(settings.makeProviderSetup())
        try fixture.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER configure_write_failure BEFORE UPDATE ON conversationInitialBinding BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
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

    private func createAndReturn(_ fixture: ShellFixture) async throws -> String {
        await fixture.model.launchRestorationTask?.value
        #expect(fixture.model.enterPreview())
        let id = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(await fixture.model.preparePreviewReturn(to: id))
        #expect(fixture.model.commitPreviewReturn())
        return id
    }
}
