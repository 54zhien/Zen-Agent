import Foundation
import Testing

@testable import ZenAgent

@Suite("Managed Files Tool")
struct FilesToolTests {
    @Test func readFreezesActualBytesAndOriginalRunDestination() throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.ingest("hello world")
        let intent = try f.prepare(file.assetID)
        #expect(intent.resourceScope == .file(assetID: file.assetID, versionID: file.versionID, contentIdentity: file.fingerprint))
        #expect(intent.destinationScope == f.context.destination)
        #expect(intent.approvalDisclosure?.targetDescription.contains(file.versionID) == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains(f.context.requestConfigSeed.endpoint.absoluteString) == true)
        #expect(intent.policyAction?.egressRequirement == .providerRequiringApproval)
    }

    @Test func readConsumesVerifiedUTF8AndPreservesTheFrozenIntent() async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.ingest("hello 世界")
        let intent = try f.prepare(file.assetID)
        let result = try await f.tool.execute(intent, idempotencyKey: "call")
        #expect(result.content == "hello 世界")
        #expect(try f.store.fileAsset(id: file.assetID)?.currentVersionID == file.versionID)
    }

    @Test func exactUTF8BudgetIsAcceptedWithoutSplittingCharacters() async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let text = String(repeating: "界", count: 21_845) + "x"
        #expect(text.utf8.count == 65_536)
        let file = try f.ingest(text)
        let result = try await f.tool.execute(f.prepare(file.assetID), idempotencyKey: "call")
        #expect(result.content == text)
    }

    @Test func symlinkedBlobCannotEscapeTheManagedRoot() async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.ingest("inside")
        let intent = try f.prepare(file.assetID)
        let blob = try f.files.blobURL(forFingerprint: file.fingerprint)
        let outside = f.root.appendingPathComponent("outside.txt")
        try Data("inside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: outside)
        do { _ = try await f.tool.execute(intent, idempotencyKey: "call"); Issue.record("Symlink must be rejected") } catch { }
    }

    @Test func aDifferentCurrentVersionCannotReplaceApprovedBytes() async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.ingest("old")
        let intent = try f.prepare(file.assetID)
        let other = try f.ingest("new")
        try f.store.advanceFileAsset(id: file.assetID,
            to: FileAssetVersionRecord(id: UUID().uuidString, assetID: file.assetID,
                contentFingerprint: other.fingerprint, byteCount: other.byteCount, mediaType: nil, createdAt: Date()))
        #expect(throws: (any Error).self) { try f.tool.validateDependencies(intent) }
        do { _ = try await f.tool.execute(intent, idempotencyKey: "call"); Issue.record("Changed version must be rejected") } catch { }
    }

    @Test func realContinuationUsesFrozenDestinationAndSanitizedFileContent() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let file = try files.ingest(data: Data("document i05-test-secret".utf8), displayName: "read.txt", in: f.store)
        let registry = try ToolRegistry(tools: [FilesTool(files: files, store: f.store)])
        try f.store.setToolPolicy(toolID: "files", actionID: "read", descriptorRevision: "2", mode: .alwaysAllow)
        let ledger = I07ProviderLedger()
        let args = try ToolArgumentJSON.normalizedObject(["assetID": file.assetID])
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: f.instance.id, scripts: [
            [.toolCall(.init(id: "file-call", index: 0, name: "files", argumentsJSON: args)), .finish(.toolCalls)],
            [.textDelta("continued"), .finish(.stop)]
        ], store: f.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials, toolRegistry: registry, managedFileStore: files)
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        do {
            var card: ToolApprovalProjection?
            for _ in 0..<1000 {
                card = try await runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID).first
                if card != nil { break }
                if try f.store.run(id: runID)?.state.isActive == false { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let approval = try #require(card)
            let call = try #require(try f.store.toolCall(id: approval.toolCallID))
            let intent = try ToolIntentCodec.decodeForDisplay(try #require(call.executionIntent))
            let seed = try #require(try f.store.run(id: runID)).requestConfigSeed
            #expect(intent.destinationScope == .provider(instanceID: f.instance.id.rawValue, endpointIdentity: seed.endpoint.absoluteString))
            #expect(approval.targetDescription.contains(file.versionID))
            #expect(approval.keyImpact.contains(seed.endpoint.absoluteString))
            try await runtime.resolveToolApproval(approval.request(for: .approveOnce))
            try await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            let payload = try #require(try f.store.toolResult(toolCallID: call.id)).payload
            #expect(payload.contains("document"))
            #expect(!payload.contains("i05-test-secret"))
            let requests = await ledger.requestsSnapshot()
            #expect(requests.count == 2)
            let returned = requests.last?.messages.compactMap { message -> String? in
                if case .toolResult(_, let content) = message { return content }; return nil
            }
            #expect(returned == [payload])
            #expect(try f.store.run(id: runID)?.state == .completed)
        } catch {
            try? await runtime.stop(runID: runID)
            try? await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            throw error
        }
    }

    @Test func escapedJSONFileCredentialsNeverReachPersistenceOrProvider() async throws {
        let f = try I05RuntimeTestFixtures.makeFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let body = #"{"data":"\u006905-test-secret","nested":[{"password":"prefix\"remaining-secret"}]}"#
        let file = try files.ingest(data: Data(body.utf8), displayName: "escaped.json", in: f.store)
        let registry = try ToolRegistry(tools: [FilesTool(files: files, store: f.store)])
        let ledger = I07ProviderLedger()
        let provider = I07ScriptedProvider(ledger: ledger, instanceID: f.instance.id, scripts: [
            [.toolCall(.init(id: "escaped-file", index: 0, name: "files",
                argumentsJSON: try ToolArgumentJSON.normalizedObject(["assetID": file.assetID]))), .finish(.toolCalls)],
            [.textDelta("continued"), .finish(.stop)]
        ], store: f.store, conversationID: I05RuntimeTestFixtures.conversationID)
        let runtime = ConversationRuntime(store: f.store, provider: provider, credentials: f.credentials,
            toolRegistry: registry, managedFileStore: files)
        let runID = try await runtime.start(I05RuntimeTestFixtures.command())
        do {
            var card: ToolApprovalProjection?
            for _ in 0..<1000 {
                card = try await runtime.pendingToolApprovals(in: I05RuntimeTestFixtures.conversationID).first
                if card != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let approval = try #require(card)
            try await runtime.resolveToolApproval(approval.request(for: .approveOnce))
            try await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            let payload = try #require(try f.store.toolResult(toolCallID: approval.toolCallID)).payload
            #expect(!payload.contains("remaining-secret"))
            let object = try ToolArgumentJSON.object(from: payload)
            #expect(object["data"] as? String != "i05-test-secret")
            let requests = await ledger.requestsSnapshot()
            let returned = requests.last?.messages.compactMap { message -> String? in
                if case .toolResult(_, let content) = message { return content }; return nil
            }
            #expect(requests.count == 2)
            #expect(returned == [payload])
        } catch {
            try? await runtime.stop(runID: runID)
            try? await Fixtures.awaitRuntimeCompletion(in: f.store, runtime: runtime, runID: runID)
            throw error
        }
    }

    @Test(arguments: ["{\"path\":\"/etc/passwd\"}", "{\"assetID\":\"../escape\"}", "{\"assetID\":\"missing\",\"destination\":\"https://evil.invalid\"}"])
    func modelPathsAndDestinationsAreRejected(arguments: String) throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        #expect(throws: (any Error).self) { try f.tool.prepare(callID: "call", argumentsJSON: arguments, context: f.context) }
    }

    @Test func corruptBytesNeverBecomeAToolResult() async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.ingest("original")
        let intent = try f.prepare(file.assetID)
        try Data("tampered".utf8).write(to: f.files.blobURL(forFingerprint: file.fingerprint))
        do { _ = try await f.tool.execute(intent, idempotencyKey: "call"); Issue.record("Corrupt bytes must fail") } catch { }
    }

    @Test(arguments: [Data(repeating: 65, count: 65_537), Data([0, 255, 3])])
    func largeAndBinaryFilesReturnBoundedReference(data: Data) async throws {
        let f = try FileToolFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: data, displayName: "data.txt", in: f.store)
        let result = try await f.tool.execute(f.prepare(file.assetID), idempotencyKey: "call")
        #expect(result.content.utf8.count < 1024)
        #expect(result.content.contains(file.assetID))
        #expect(result.content.contains(file.versionID))
    }
}

private struct FileToolFixture: Sendable {
    let root: URL
    let store: PersistenceStore
    let files: ManagedFileStore
    let context: ToolPreparationContext
    var tool: FilesTool { FilesTool(files: files, store: store) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        context = ToolPreparationContext(requestConfigSeed: try #require(try store.run(id: "r")).requestConfigSeed)
    }
    func ingest(_ text: String) throws -> ManagedFileDescriptor { try files.ingest(data: Data(text.utf8), displayName: "note.txt", in: store) }
    func prepare(_ assetID: String) throws -> ToolExecutionIntent {
        try tool.prepare(callID: "call", argumentsJSON: ToolArgumentJSON.normalizedObject(["assetID": assetID]), context: context)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
