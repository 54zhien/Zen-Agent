import Foundation
import Testing

@testable import ZenAgent

@Suite("Settings edit scope")
@MainActor
struct SettingsScopeTests {
    @Test("explicit Configure initializes the captured New without replacing its editor or creating a row")
    func configureKeepsTheUncommittedNewOwner() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none, createInstance: false, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        let shell = fixture.model
        let pane = try #require(shell.pane)
        let id = shell.conversationID
        pane.composer.draft.text = "captured New draft"
        let settings = try #require(shell.makeSettingsModel(configureNewID: id))
        let setup = try #require(settings.makeProviderSetup())
        setup.apiKey = "settings-new-fixture-secret"
        #expect(setup.save())
        #expect(shell.pane === pane && shell.conversationID == id)
        #expect(pane.composer.configuration?.providerInstanceID == setup.instanceID)
        #expect(pane.composer.draft.text == "captured New draft")
        #expect(try fixture.store.conversationLifecycle(id: id) == nil)
    }

    @Test("a stale Configure callback cannot retarget a later New owner")
    func configureDoesNotMoveToALaterNew() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .none, createInstance: false, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        let shell = fixture.model
        let settings = try #require(shell.makeSettingsModel(configureNewID: shell.conversationID))
        let setup = try #require(settings.makeProviderSetup())
        shell.newConversation()
        let later = try #require(shell.pane)
        setup.apiKey = "settings-stale-fixture-secret"
        #expect(setup.save())
        #expect(shell.pane === later && later.composer.configuration == nil)
        shell.newConversation()
        #expect(shell.pane?.composer.configuration?.providerInstanceID == setup.instanceID)
    }

    @Test("the global default leaves both existing Pane configurations unchanged")
    func defaultSelectionOnlyAppliesToFutureConversations() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        let shell = fixture.model
        let source = try #require(shell.pane?.session)
        #expect(shell.commitSplitDrop(SplitDropIntent(conversationID: source.conversationID, slot: .top)))
        #expect(shell.createNewInSplit())
        let secondary = try #require(shell.splitPane?.session)
        let sourceConfiguration = source.composer.configuration
        let secondaryConfiguration = secondary.composer.configuration
        let newInstanceID = ProviderInstanceID(rawValue: "settings-new-instance")
        try fixture.store.createProviderInstance(ProviderInstance(id: newInstanceID,
            providerID: .deepSeek, displayName: "Another instance", baseURL: nil,
            configRevision: .initial, credentialReference: fixture.reference))
        let settings = try #require(shell.makeSettingsModel())
        #expect(await settings.setDefault(providerInstanceID: newInstanceID, modelID: fixture.modelID))
        #expect(source.composer.configuration == sourceConfiguration)
        #expect(secondary.composer.configuration == secondaryConfiguration)
        #expect(fixture.defaults.string(forKey: AppShellModel.defaultInstanceIDKey) == newInstanceID.rawValue)
        shell.newConversation()
        #expect(shell.pane?.composer.configuration?.providerInstanceID == newInstanceID)
        #expect(shell.pane?.composer.configuration?.modelID == fixture.modelID)
    }

    @Test("saving Soul advances its version while preserving the existing Conversation binding")
    func soulSaveKeepsOldConversationBinding() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createSoul(initialVersion: SoulVersionRecord(id: "old-soul",
            instructions: "old instructions", createdAt: Fixtures.epoch), at: Fixtures.epoch)
        try store.createEmptyConversation(id: "old-conversation", at: Fixtures.epoch)
        let editor = SoulSettingsModel(store: store)
        await editor.load()
        editor.instructions = "new instructions"
        await editor.save()

        #expect(try store.currentSoulVersion()?.instructions == "new instructions")
        #expect(try store.boundSoulVersion(conversationID: "old-conversation")?.id == "old-soul")
        #expect(try store.effectiveSoulVersion(conversationID: "old-conversation")?.instructions == "old instructions")
    }

    @Test("a conflicting Soul editor retains typed text and cannot overwrite the accepted edit")
    func conflictingSoulEditKeepsItsLocalDraft() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createSoul(initialVersion: SoulVersionRecord(id: "base-soul",
            instructions: "baseline", createdAt: Fixtures.epoch), at: Fixtures.epoch)
        let first = SoulSettingsModel(store: store)
        let second = SoulSettingsModel(store: store)
        await first.load()
        await second.load()
        first.instructions = "accepted edit"
        second.instructions = "unsaved conflicting draft"
        await first.save()
        await second.save()

        #expect(try store.currentSoulVersion()?.instructions == "accepted edit")
        #expect(second.instructions == "unsaved conflicting draft")
        #expect(second.errorMessage != nil)
    }

    @Test("saving instructions while Soul is disabled preserves the explicit global disable")
    func soulEditDoesNotImplicitlyEnableInjection() async throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createSoul(initialVersion: SoulVersionRecord(id: "disabled-soul",
            instructions: "original", createdAt: Fixtures.epoch), at: Fixtures.epoch)
        try store.createEmptyConversation(id: "bound-before-disable", at: Fixtures.epoch)
        try store.setSoulEnabled(false, at: Fixtures.epoch.addingTimeInterval(1))
        let editor = SoulSettingsModel(store: store)
        await editor.load()
        editor.instructions = "edited while disabled"
        await editor.save()

        #expect(try store.soul()?.enabled == false)
        #expect(try store.boundSoulVersion(conversationID: "bound-before-disable")?.id == "disabled-soul")
        #expect(try store.effectiveSoulVersion(conversationID: "bound-before-disable") == nil)
        try store.createEmptyConversation(id: "created-while-disabled", at: Fixtures.epoch.addingTimeInterval(2))
        #expect(try store.boundSoulVersion(conversationID: "created-while-disabled") == nil)
    }
}
