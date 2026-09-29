import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation Card metadata")
struct ConversationMetadataTests {
    @Test("metadata edits preserve activity, become manual, and stale Send cannot overwrite them")
    func manualRenameAndPinPreserveActivity() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let first = Fixtures.send(messageID: "meta-m1", runID: "meta-r1", runState: .completed)
        try store.commitUserTurnAndCreateParentRun(first)
        let stale = try #require(try store.conversation(id: "c1"))
        let later = Fixtures.epoch.addingTimeInterval(60)
        try store.renameConversation(id: "c1", title: "  手动 🧑🏽‍💻 标题  ", at: later)
        try store.setConversationPinned(id: "c1", pinned: true, at: later)
        let after = try #require(try store.conversation(id: "c1"))
        #expect(after.title == "手动 🧑🏽‍💻 标题")
        #expect(after.pinned)
        #expect(after.userActiveAt == stale.userActiveAt && after.createdAt == stale.createdAt)
        #expect(after.updatedAt == later)
        #expect(try store.hasManualConversationTitle(id: "c1"))
        var second = Fixtures.send(messageID: "meta-m2", runID: "meta-r2", runState: .completed)
        second.conversation = stale
        second.message.sequence = 1
        second.message.createdAt = later.addingTimeInterval(1)
        try store.commitUserTurnAndCreateParentRun(second)
        #expect(try store.conversation(id: "c1")?.title == "手动 🧑🏽‍💻 标题")
        #expect(try store.conversation(id: "c1")?.pinned == true)
        #expect(try store.hasManualConversationTitle(id: "c1"))
    }

    @Test("empty creation copies an initial binding and metadata edits preserve it")
    func copiedInitialBindingIsDurableMetadata() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let binding = ConversationInitialBinding(providerInstanceID: ProviderInstanceID(rawValue: "frozen-account"), modelID: ModelID(rawValue: "frozen-model"))
        try store.createEmptyConversation(id: "bound-empty", at: Fixtures.epoch, initialBinding: binding)
        #expect(try store.conversationInitialBinding(id: "bound-empty") == binding)
        try store.renameConversation(id: "bound-empty", title: "manual", at: Fixtures.epoch)
        try store.setConversationPinned(id: "bound-empty", pinned: true, at: Fixtures.epoch)
        #expect(try store.conversationInitialBinding(id: "bound-empty") == binding)
        #expect(try store.conversationInitialBinding(id: "missing") == nil)
    }

    @Test("an explicitly unconfigured empty history accepts an explicit initial choice only once")
    func unconfiguredInitialChoiceIsExplicitAndOnce() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createEmptyConversation(id: "unconfigured", at: Fixtures.epoch)
        let choice = ConversationInitialBinding(providerInstanceID: ProviderInstanceID(rawValue: "chosen-account"), modelID: ModelID(rawValue: "chosen-model"))
        #expect(try store.initializeEmptyConversationBinding(id: "unconfigured", binding: choice, at: Fixtures.epoch))
        #expect(try store.conversationInitialBinding(id: "unconfigured") == choice)
        #expect(try store.initializeEmptyConversationBinding(id: "unconfigured", binding: .init(providerInstanceID: ProviderInstanceID(rawValue: "other"), modelID: ModelID(rawValue: "other")), at: Fixtures.epoch) == false)
        #expect(try store.conversationInitialBinding(id: "unconfigured") == choice)
        #expect(try store.conversation(id: "unconfigured")?.userActiveAt == Fixtures.epoch)
    }

    @Test("blank names, deleted targets and failed writes leave metadata untouched")
    func invalidAndFailedEditsAreAtomic() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            try Fixtures.conversation().insert(db)
            try Fixtures.conversation(id: "hidden", lifecycle: .pendingDeletion).insert(db)
        }
        let before = try #require(try store.conversation(id: "c1"))
        #expect(throws: (any Error).self) { try store.renameConversation(id: "c1", title: " \n\t ", at: Fixtures.epoch) }
        #expect(throws: (any Error).self) { try store.renameConversation(id: "hidden", title: "not allowed", at: Fixtures.epoch) }
        #expect(throws: (any Error).self) { try store.setConversationPinned(id: "missing", pinned: true, at: Fixtures.epoch) }
        try store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER metadata_failure BEFORE UPDATE ON conversation BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        }
        #expect(throws: (any Error).self) { try store.renameConversation(id: "c1", title: "must roll back", at: Fixtures.epoch) }
        #expect(try store.conversation(id: "c1")?.title == before.title)
        #expect(try store.hasManualConversationTitle(id: "c1") == false)
    }

    @Test("empty explicit creation is durable, binds current Soul once, and does not start a Run")
    func emptyCreationBindsSoulAndRejectsDuplicates() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.createSoul(initialVersion: SoulVersionRecord(id: "meta-soul-1", instructions: "first", createdAt: Fixtures.epoch), at: Fixtures.epoch)
        try store.createEmptyConversation(id: "empty", at: Fixtures.epoch)
        #expect(try store.conversation(id: "empty")?.lifecycle == .visible)
        #expect(try store.conversation(id: "empty")?.userActiveAt == Fixtures.epoch)
        #expect(try store.conversationSummaryPage().items.map(\.id) == ["empty"])
        #expect(try store.messages(inConversation: "empty").isEmpty)
        #expect(try store.activeParentRunIDs().isEmpty)
        #expect(try store.effectiveSoulVersion(conversationID: "empty")?.id == "meta-soul-1")
        try store.advanceSoul(expectedCurrentVersionID: "meta-soul-1", to: SoulVersionRecord(id: "meta-soul-2", instructions: "second", createdAt: Fixtures.epoch), at: Fixtures.epoch)
        #expect(throws: (any Error).self) { try store.createEmptyConversation(id: "empty", at: Fixtures.epoch) }
        #expect(try store.effectiveSoulVersion(conversationID: "empty")?.id == "meta-soul-1")
        try store.renameConversation(id: "empty", title: "manual before Send", at: Fixtures.epoch)
        var first = Fixtures.send(conversationID: "empty", messageID: "empty-m", runID: "empty-r", runState: .completed)
        first.conversation.title = "stale title"
        try store.commitUserTurnAndCreateParentRun(first)
        #expect(try store.conversation(id: "empty")?.title == "manual before Send")
        #expect(try store.effectiveSoulVersion(conversationID: "empty")?.id == "meta-soul-1")
    }
    @Test("manual marker and empty history survive closing and reopening the database")
    func manualMarkerSurvivesReopen() throws {
        let url = try Fixtures.scratchPath(name: "metadata-reopen.sqlite")
        defer { Fixtures.cleanUp(url) }
        do {
            let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
            try store.createEmptyConversation(id: "durable-empty", at: Fixtures.epoch, initialBinding: .init(providerInstanceID: ProviderInstanceID(rawValue: "durable-account"), modelID: ModelID(rawValue: "durable-model")))
            try store.renameConversation(id: "durable-empty", title: "持久手动标题", at: Fixtures.epoch)
            try store.setConversationPinned(id: "durable-empty", pinned: true, at: Fixtures.epoch)
        }
        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(try reopened.conversation(id: "durable-empty")?.title == "持久手动标题")
        #expect(try reopened.conversation(id: "durable-empty")?.pinned == true)
        #expect(try reopened.hasManualConversationTitle(id: "durable-empty"))
        #expect(try reopened.conversationInitialBinding(id: "durable-empty")?.providerInstanceID?.rawValue == "durable-account")
        #expect(try reopened.messages(inConversation: "durable-empty").isEmpty)
    }

}
