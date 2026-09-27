import Foundation
import Testing

@testable import ZenAgent

@Suite("App cold-start recovery")
@MainActor
struct AppColdStartRecoveryTests {
    @Test("a frozen preparing run attaches one real continuation after disk reopen")
    func frozenPreparingRunAttachesContinuation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-prepare-reopen-\(UUID().uuidString).sqlite")
        let runID = "prepare-\(UUID().uuidString)"
        let conversationID = "conversation-\(runID)"
        do {
            let first = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            try first.createProviderInstance(ProviderInstance(
                id: ProviderInstanceID(rawValue: "pi1"),
                providerID: .deepSeek,
                displayName: "DeepSeek",
                baseURL: nil,
                configRevision: ConfigRevision(rawValue: "config-r1"),
                credentialReference: CredentialReference(id: "cred-1")
            ))
            try first.commitUserTurnAndCreateParentRun(Fixtures.send(
                conversationID: conversationID,
                messageID: "user-\(runID)",
                runID: runID,
                runState: .preparing
            ))
            let snapshot = RunExecutionSnapshot(
                providerID: .deepSeek,
                providerAdapterRevision: "stage2-gate-scripted-provider.v1",
                prompt: PromptExecutionSnapshot(
                    runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                    zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                    providerAdapterInstructions: ""
                ),
                modelCapabilities: [.text, .streaming],
                exposedTools: [],
                maxProviderSteps: 4
            )
            try first.completeExecutionSnapshot(
                runID: runID,
                encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
            )
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("test-only-secret"),
            as: CredentialReference(id: "cred-1")
        )
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [.events([.textDelta("resumed"), .finish(.stop)])]
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: reopened,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: reopened,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.PrepareRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shell = AppShellModel(dependencies: dependencies, userDefaults: defaults)

        for _ in 0..<200 {
            if try reopened.run(id: runID)?.state == .completed,
               shell.launchState == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(try reopened.run(id: runID))
        #expect(run.id == runID)
        #expect(run.state == .completed)
        #expect(try reopened.steps(inRun: runID).count == 1)
        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.messages.contains(.user("hello")) == true)
    }
}
