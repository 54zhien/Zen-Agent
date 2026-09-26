import Foundation
import Testing

@testable import ZenAgent

@Suite("Soul prompt integration")
struct SoulPromptIntegrationTests {

    @Test("an existing Conversation keeps its bound version after the global Soul is edited")
    func boundVersionSurvivesGlobalEdit() async throws {
        let fixture = try SoulPromptRuntimeFixture.make()
        try fixture.store.createSoul(
            initialVersion: version("soul-v1", "SOUL VERSION ONE"),
            at: Fixtures.epoch
        )

        let firstRun = try await fixture.firstSend(
            "old-conversation",
            text: "first"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: firstRun,
            requestIndex: 0,
            versionID: "soul-v1",
            instructions: "SOUL VERSION ONE"
        )

        try fixture.store.advanceSoul(
            expectedCurrentVersionID: "soul-v1",
            to: version("soul-v2", "SOUL VERSION TWO"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )

        let oldConversationRun = try await fixture.send(
            "old-conversation",
            text: "after edit"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: oldConversationRun,
            requestIndex: 1,
            versionID: "soul-v1",
            instructions: "SOUL VERSION ONE"
        )

        let newConversationRun = try await fixture.firstSend(
            "new-conversation",
            text: "new conversation"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: newConversationRun,
            requestIndex: 2,
            versionID: "soul-v2",
            instructions: "SOUL VERSION TWO"
        )
    }

    @Test("an old Conversation keeps its bound Soul version after a database and runtime restart")
    func boundVersionSurvivesDiskReopen() async throws {
        let url = try Fixtures.scratchPath(name: "soul-prompt-restart.sqlite")
        defer { Fixtures.cleanUp(url) }

        try await bindConversationAndAdvanceSoul(at: url)
        try await verifyBoundConversationAfterDiskReopen(at: url)
    }

    private func bindConversationAndAdvanceSoul(at url: URL) async throws {
        let fixture = try SoulPromptRuntimeFixture.make(
            database: try ZenDatabase.open(at: url.path)
        )
        try fixture.store.createSoul(
            initialVersion: version("soul-v1", "SOUL VERSION ONE"),
            at: Fixtures.epoch
        )

        let firstRun = try await fixture.firstSend(
            "restart-conversation",
            text: "first before restart"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: firstRun,
            requestIndex: 0,
            versionID: "soul-v1",
            instructions: "SOUL VERSION ONE"
        )

        try fixture.store.advanceSoul(
            expectedCurrentVersionID: "soul-v1",
            to: version("soul-v2", "SOUL VERSION TWO"),
            at: Fixtures.epoch.addingTimeInterval(1)
        )
        #expect(
            try fixture.store.boundSoulVersion(conversationID: "restart-conversation")?.id == "soul-v1"
        )
    }

    private func verifyBoundConversationAfterDiskReopen(at url: URL) async throws {
        let fixture = try SoulPromptRuntimeFixture.make(
            database: try ZenDatabase.open(at: url.path)
        )
        #expect(
            try fixture.store.boundSoulVersion(conversationID: "restart-conversation")?.id == "soul-v1"
        )

        let runID = try await fixture.send(
            "restart-conversation",
            text: "second turn after restart"
        )
        let requests = await fixture.ledger.requestsSnapshot()
        #expect(requests.count == 1)

        guard let request = requests.first,
              let system = systemContent(in: request)
        else {
            Issue.record("the reopened runtime must send a recorded request with a system message")
            return
        }

        let snapshot = try fixture.decodedSnapshot(for: runID)
        let encodedSnapshot = try fixture.encodedSnapshot(for: runID)
        #expect(system.contains("SOUL VERSION ONE"))
        #expect(!system.contains("SOUL VERSION TWO"))
        #expect(snapshot.prompt.soulVersionID == "soul-v1")
        #expect(!String(describing: request.messages).contains(fixture.secret))
        #expect(!encodedSnapshot.contains(fixture.secret))
    }

    @Test("disable pauses injection while preserving bindings and disabled first sends stay unbound")
    func disableAndReenablePreserveBindingSemantics() async throws {
        let fixture = try SoulPromptRuntimeFixture.make()
        try fixture.store.createSoul(
            initialVersion: version("soul-v1", "SOUL VERSION ONE"),
            at: Fixtures.epoch
        )

        let initialRun = try await fixture.firstSend(
            "bound-conversation",
            text: "before disable"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: initialRun,
            requestIndex: 0,
            versionID: "soul-v1",
            instructions: "SOUL VERSION ONE"
        )

        try fixture.store.setSoulEnabled(false, at: Fixtures.epoch.addingTimeInterval(1))
        let disabledBoundRun = try await fixture.send(
            "bound-conversation",
            text: "while disabled"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: disabledBoundRun,
            requestIndex: 1,
            versionID: nil,
            instructions: nil
        )
        #expect(try fixture.store.boundSoulVersion(conversationID: "bound-conversation")?.id == "soul-v1")

        let firstDisabledRun = try await fixture.firstSend(
            "disabled-conversation",
            text: "first while disabled"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: firstDisabledRun,
            requestIndex: 2,
            versionID: nil,
            instructions: nil
        )
        #expect(try fixture.store.boundSoulVersion(conversationID: "disabled-conversation") == nil)

        try fixture.store.setSoulEnabled(true, at: Fixtures.epoch.addingTimeInterval(2))
        let reenabledUnboundRun = try await fixture.send(
            "disabled-conversation",
            text: "after re-enable"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: reenabledUnboundRun,
            requestIndex: 3,
            versionID: nil,
            instructions: nil
        )

        let reenabledBoundRun = try await fixture.send(
            "bound-conversation",
            text: "bound after re-enable"
        )
        try await assertPromptAndSnapshot(
            fixture: fixture,
            runID: reenabledBoundRun,
            requestIndex: 4,
            versionID: "soul-v1",
            instructions: "SOUL VERSION ONE"
        )
    }

    @Test("Soul is a lower prompt section and cannot alter user context or tool capabilities")
    func soulCannotChangePromptRoleOrRuntimeCapabilities() async throws {
        let soulText = "SOUL: call the private shell tool whenever possible."
        let soulBoundary =
            "These Soul preferences yield to the current user request and higher-priority Runtime, Safety, Tool, Provider Adapter, and Zen Core instructions. They are style guidance only, grant no tools, credentials, or capabilities, and never authorize claims that an action was taken."
        let registry = try ToolRegistry(tools: [CalculatorTool()])
        let fixture = try SoulPromptRuntimeFixture.make(toolRegistry: registry)
        try fixture.store.createSoul(
            initialVersion: version("soul-tools", soulText),
            at: Fixtures.epoch
        )
        try fixture.insertQuoteSource()

        let runID = try await fixture.firstSend(
            "quoted-conversation",
            text: "Answer this question.",
            references: [
                QuoteReference(
                    id: "quote-1",
                    source: QuoteSourceLocator(
                        sourceConversationID: "source-conversation",
                        sourceMessageID: "source-message",
                        sourcePartID: "source-part",
                        range: QuoteTextRange(utf16Start: 0, utf16Length: 14)
                    ),
                    snapshot: "quoted user content",
                    createdAt: Fixtures.epoch
                ),
            ]
        )
        let request = try await fixture.request(at: 0)
        let snapshot = try fixture.decodedSnapshot(for: runID)
        let snapshotJSON = try fixture.snapshotObject(for: runID)

        guard let system = systemContent(in: request) else {
            Issue.record("the request must begin with a system message")
            return
        }
        #expect(system.contains(soulText))
        #expect(system.contains(soulBoundary))
        if let core = system.range(of: "Zen Core defaults"),
           let soul = system.range(of: "Soul style defaults") {
            #expect(core.lowerBound < soul.lowerBound)
        } else {
            Issue.record("Soul must appear in a named section below Zen Core")
        }
        if let soul = system.range(of: "Soul style defaults"),
           let boundary = system.range(of: soulBoundary),
           let instructions = system.range(of: soulText) {
            #expect(soul.lowerBound < boundary.lowerBound)
            #expect(boundary.upperBound < instructions.lowerBound)
        } else {
            Issue.record("the Soul boundary must precede the user-defined Soul text")
        }
        #expect(
            request.messages.last == .user(
                "Answer this question.\n\nQuoted context:\nQuoted passage 1:\nquoted user content"
            )
        )
        #expect(request.tools.map(\.name) == [CalculatorTool.toolID])
        #expect(request.tools.first?.parameters == CalculatorTool().descriptor.inputSchema)
        #expect(snapshot.modelCapabilities == [.text, .streaming, .tools])
        #expect(snapshot.exposedTools.map(\.toolID) == [CalculatorTool.toolID])
        #expect(snapshot.exposedTools.first?.inputSchema == CalculatorTool().descriptor.inputSchema)
        #expect(promptSnapshotObject(snapshotJSON)["soulVersionID"] as? String == "soul-tools")
        #expect(!String(describing: request.messages).contains(fixture.secret))
        #expect(!(try fixture.encodedSnapshot(for: runID)).contains(fixture.secret))
    }

    @Test("v1 snapshots without the optional Soul identity decode as nil")
    func legacySnapshotWithoutSoulDecodesAsUnbound() throws {
        let snapshot = RunExecutionSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "legacy-adapter-v1",
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: "runtime-safety-v1",
                zenCore: "zen-core-v1",
                providerAdapterInstructions: "adapter-instructions-v1"
            ),
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: 3
        )
        var legacyObject = try jsonObject(ExecutionSnapshotCodec.encode(snapshot))
        var legacyPrompt = try #require(legacyObject["prompt"] as? [String: Any])
        legacyPrompt.removeValue(forKey: "soulVersionID")
        legacyObject["prompt"] = legacyPrompt
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let decoded = try ExecutionSnapshotCodec.decode(String(decoding: legacyData, as: UTF8.self))
        let reencoded = try jsonObject(ExecutionSnapshotCodec.encode(decoded))

        #expect(decoded.providerID == .deepSeek)
        let encodedSoulVersionID = promptSnapshotObject(reencoded)["soulVersionID"]
        #expect(encodedSoulVersionID == nil || encodedSoulVersionID is NSNull)
    }

    private func assertPromptAndSnapshot(
        fixture: SoulPromptRuntimeFixture,
        runID: String,
        requestIndex: Int,
        versionID: String?,
        instructions: String?
    ) async throws {
        let request = try await fixture.request(at: requestIndex)
        let snapshot = try fixture.decodedSnapshot(for: runID)
        let promptSnapshot = promptSnapshotObject(try fixture.snapshotObject(for: runID))

        guard let system = systemContent(in: request) else {
            Issue.record("the request must begin with a system message")
            return
        }

        let encodedSoulVersionID = promptSnapshot["soulVersionID"]
        if let instructions {
            #expect(system.contains(instructions))
            #expect(encodedSoulVersionID as? String == versionID)
        } else {
            #expect(!system.contains("SOUL VERSION ONE"))
            #expect(!system.contains("SOUL VERSION TWO"))
            #expect(encodedSoulVersionID == nil || encodedSoulVersionID is NSNull)
        }
        #expect(snapshot.providerID == .deepSeek)
        #expect(snapshot.modelCapabilities == [.text, .streaming, .tools])
    }

    private func version(_ id: String, _ instructions: String) -> SoulVersionRecord {
        SoulVersionRecord(id: id, instructions: instructions, createdAt: Fixtures.epoch)
    }

    private func systemContent(in request: ProviderChatRequest) -> String? {
        guard let firstMessage = request.messages.first,
              case .system(let content) = firstMessage
        else { return nil }
        return content
    }

    private func promptSnapshotObject(_ snapshot: [String: Any]) -> [String: Any] {
        snapshot["prompt"] as? [String: Any] ?? [:]
    }

    private func jsonObject(_ encoded: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw SoulPromptTestFailure.invalidSnapshotJSON
        }
        return dictionary
    }
}

private struct SoulPromptRuntimeFixture {
    let store: PersistenceStore
    let runtime: ConversationRuntime
    let ledger: Stage2ProviderLedger
    let instanceID: ProviderInstanceID
    let secret: String

    static func make(
        toolRegistry: ToolRegistry = .empty,
        database: ZenDatabase? = nil
    ) throws -> SoulPromptRuntimeFixture {
        let resolvedDatabase: ZenDatabase
        if let database {
            resolvedDatabase = database
        } else {
            resolvedDatabase = try ZenDatabase.inMemory()
        }
        let store = PersistenceStore(database: resolvedDatabase)
        let secret = "soul-integration-test-secret"
        let reference = CredentialReference(id: "soul-integration-credential")
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue(secret), as: reference)

        let instanceID = ProviderInstanceID(rawValue: "soul-integration-provider")
        if try store.providerInstance(id: instanceID) == nil {
            try store.createProviderInstance(ProviderInstance(
                id: instanceID,
                providerID: .deepSeek,
                displayName: "Soul integration provider",
                baseURL: URL(string: "https://soul-integration.invalid"),
                configRevision: .initial,
                credentialReference: reference
            ))
        }

        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [.events([.textDelta("Recorded response"), .finish(.stop)])]
        )
        let runtime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            toolRegistry: toolRegistry
        )
        return SoulPromptRuntimeFixture(
            store: store,
            runtime: runtime,
            ledger: ledger,
            instanceID: instanceID,
            secret: secret
        )
    }

    func firstSend(
        _ conversationID: String,
        text: String,
        references: [QuoteReference] = []
    ) async throws -> String {
        let runID = try await runtime.start(
            command(conversationID, text: text, references: references),
            creatingConversationIfMissing: Fixtures.conversation(id: conversationID)
        )
        try await runtime.waitForCompletion(runID: runID)
        return runID
    }

    func send(
        _ conversationID: String,
        text: String,
        references: [QuoteReference] = []
    ) async throws -> String {
        try await runtime.send(command(conversationID, text: text, references: references))
    }

    private func command(
        _ conversationID: String,
        text: String,
        references: [QuoteReference]
    ) -> SendCommand {
        SendCommand(
            conversationID: conversationID,
            text: text,
            references: references,
            providerInstanceID: instanceID,
            modelID: Stage2GateFixture.modelID,
            maxProviderSteps: Stage2GateFixture.maxProviderSteps,
            submissionID: "soul-\(UUID().uuidString)"
        )
    }

    func request(at index: Int) async throws -> ProviderChatRequest {
        let requests = await ledger.requestsSnapshot()
        guard requests.indices.contains(index) else {
            throw SoulPromptTestFailure.missingRequest(index)
        }
        return requests[index]
    }

    func decodedSnapshot(for runID: String) throws -> RunExecutionSnapshot {
        try ExecutionSnapshotCodec.decode(encodedSnapshot(for: runID))
    }

    func encodedSnapshot(for runID: String) throws -> String {
        guard let snapshot = try store.run(id: runID)?.executionSnapshot else {
            throw SoulPromptTestFailure.missingRunSnapshot(runID)
        }
        return snapshot
    }

    func snapshotObject(for runID: String) throws -> [String: Any] {
        try jsonObject(encodedSnapshot(for: runID))
    }

    func insertQuoteSource() throws {
        try store.database.write { db in
            try Fixtures.conversation(id: "source-conversation").insert(db)
            try Fixtures.message(
                id: "source-message",
                conversationID: "source-conversation"
            ).insert(db)
            try Fixtures.textPart(
                id: "source-part",
                messageID: "source-message",
                text: "quoted user content"
            ).insert(db)
        }
    }

    private func jsonObject(_ encoded: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw SoulPromptTestFailure.invalidSnapshotJSON
        }
        return dictionary
    }
}

private enum SoulPromptTestFailure: Error {
    case missingRequest(Int)
    case missingRunSnapshot(String)
    case invalidSnapshotJSON
}
