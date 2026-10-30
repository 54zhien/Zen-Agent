import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Subagent configuration")
struct DelegationConfigurationTests {
    @Test("v28 delegation settings retain their state and follow Parent after v29")
    func v28RowMigratesWithoutAnExplicitTarget() throws {
        let database = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(database, upTo: "v28_run_measurements")
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO agentDelegationSettings(id, enabled, revision, updatedAt)
                VALUES ('global', ?, ?, ?)
                """, arguments: [true, 4, Fixtures.epoch])
        }

        try migrator.migrate(database)

        let configuration = try PersistenceStore(database: database).delegationConfiguration()
        #expect(configuration.enabled)
        #expect(configuration.explicitModelTarget == nil)
        #expect(configuration.revision == 4)
    }

    @Test("model target and enabled state update one revision while legacy toggle preserves target")
    func configurationPersistsModelTargetAndPreservesItWhenToggled() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let initial = try store.delegationConfiguration()
        #expect(!initial.enabled)
        #expect(initial.explicitModelTarget == nil)
        #expect(initial.revision == 0)

        let target = DelegationModelTarget(
            providerInstanceID: ProviderInstanceID(rawValue: "provider-instance"),
            modelID: ModelID(rawValue: "model-id")
        )
        let selected = try store.setDelegationConfiguration(
            enabled: true,
            explicitModelTarget: target,
            at: Fixtures.epoch
        )
        #expect(selected.enabled)
        #expect(selected.explicitModelTarget == target)
        #expect(selected.revision == 1)

        let unchanged = try store.setDelegationConfiguration(
            enabled: true,
            explicitModelTarget: target,
            at: Fixtures.epoch.addingTimeInterval(1)
        )
        #expect(unchanged.revision == 1)

        let disabled = try store.setDelegationEnabled(false, at: Fixtures.epoch.addingTimeInterval(2))
        #expect(!disabled.enabled)
        #expect(disabled.explicitModelTarget == target)
        #expect(disabled.revision == 2)

        let persisted = try store.delegationConfiguration()
        #expect(persisted == disabled)
    }
}
