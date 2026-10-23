import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Managed Files Tool writes")
@MainActor
struct FilesToolWriteTests {
    @Test func fileExecutorDoesNotOwnItsPresentationSessionStore() throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        var owner: ConversationSessionStore? = ConversationSessionStore()
        weak var observed = owner
        let registry = try ToolRegistry(tools: [FilesTool(files: f.files, store: f.store, sessions: owner)])
        owner = nil
        withExtendedLifetime(registry) { #expect(observed == nil) }
    }

    @Test func createRequiresExactApprovalAndPublishesManagedBytes() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let call = try await f.prepare(["action": "create", "displayName": "created.txt", "content": "new bytes"])
        #expect(try f.store.toolResult(toolCallID: call.id) == nil)
        let intent = try ToolIntentCodec.decodeForDisplay(try #require(call.executionIntent))
        #expect(intent.policyAction?.actionID == "create")
        #expect(intent.policyAction?.requiresExplicitApproval == true)
        let result = try await f.approveAndExecute(call)
        let reference = try ToolArgumentJSON.object(from: result.content)
        let assetID = try #require(reference["assetID"] as? String)
        let versionID = try #require(reference["versionID"] as? String)
        let version = try #require(try f.store.fileAssetVersion(id: versionID))
        #expect(try f.store.fileAsset(id: assetID)?.origin == .generated)
        #expect(try Data(contentsOf: f.files.blobURL(forFingerprint: version.contentFingerprint)) == Data("new bytes".utf8))
        #expect(try f.store.toolCall(id: call.id)?.state == .succeeded)
    }

    @Test func modifyKeepsHistoricalMessageVersionAndPublishesNewVersion() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: Data("old bytes".utf8), displayName: "old.txt", in: f.store)
        try f.store.database.write { db in
            try MessageAttachmentRecord(id: "old-attachment", messageID: "m", assetID: file.assetID,
                versionID: file.versionID, sequence: 0).insert(db)
        }
        let call = try await f.prepare(["action": "modify", "assetID": file.assetID, "expectedVersionID": file.versionID, "content": "new bytes"])
        _ = try await f.approveAndExecute(call)
        let current = try #require(try f.store.fileAsset(id: file.assetID))
        #expect(current.currentVersionID != file.versionID)
        #expect(try f.store.attachments(forMessage: "m").first?.versionID == file.versionID)
        #expect(try Data(contentsOf: f.files.blobURL(forFingerprint: file.fingerprint)) == Data("old bytes".utf8))
        let version = try #require(try f.store.fileAssetVersion(id: current.currentVersionID))
        #expect(try Data(contentsOf: f.files.blobURL(forFingerprint: version.contentFingerprint)) == Data("new bytes".utf8))
    }

    @Test func versionChangeAfterApprovalCannotBeOverwritten() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: Data("old".utf8), displayName: "old.txt", in: f.store)
        let call = try await f.prepare(["action": "modify", "assetID": file.assetID, "expectedVersionID": file.versionID, "content": "tool bytes"])
        try f.approve(call)
        let nextID = UUID().uuidString
        try f.store.advanceFileAsset(id: file.assetID, to: .init(id: nextID, assetID: file.assetID,
            contentFingerprint: file.fingerprint, byteCount: file.byteCount, mediaType: file.mediaType, createdAt: Date()))
        _ = try await f.runtime.executeApproved(toolCallID: call.id)
        #expect(try f.store.toolCall(id: call.id)?.state == .rejected)
        #expect(try f.store.toolCall(id: call.id)?.failureReason == .dependencyChanged)
        #expect(try f.store.fileAsset(id: file.assetID)?.currentVersionID == nextID)
    }

    @Test func deleteUsesActualRetainedSessionOwnerAndSharedDigestReferences() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: Data("shared".utf8), displayName: "a.txt", in: f.store)
        let other = try f.files.ingest(data: Data("shared".utf8), displayName: "b.txt", in: f.store)
        let warm = ConversationSession(conversationID: "warm", configuration: nil)
        warm.composer.draft.attachments = [.init(id: file.assetID, versionID: file.versionID,
            fingerprint: file.fingerprint, displayName: file.displayName, kind: .file)]
        f.sessions.retain(warm, reconstruction: .history(configuration: nil))
        let protected = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        _ = try await f.approveAndExecute(protected)
        #expect(try f.store.fileAsset(id: file.assetID) != nil)
        warm.composer.draft.attachments = []
        let allowed = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        _ = try await f.approveAndExecute(allowed)
        #expect(try f.store.fileAsset(id: file.assetID) == nil)
        #expect(try f.store.fileAsset(id: other.assetID) != nil)
        #expect(try Data(contentsOf: f.files.blobURL(forFingerprint: other.fingerprint)) == Data("shared".utf8))
    }

    @Test func aCommittedWriteIsConfirmedAfterResultCommitCrashWithoutReplay() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let call = try await f.prepare(["action": "create", "displayName": "receipt.txt", "content": "once"])
        try f.approve(call)
        try f.store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER injected_result_failure BEFORE UPDATE OF state ON toolCall WHEN NEW.state = 'succeeded' BEGIN SELECT RAISE(ABORT, 'result-commit-fault'); END")
        }
        do { _ = try await f.runtime.executeApproved(toolCallID: call.id); Issue.record("Injected result commit must fail") } catch { }
        #expect(try f.store.toolCall(id: call.id)?.state == .dispatched)
        let before = try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") }
        #expect(before == 1)
        try f.store.database.write { try $0.execute(sql: "DROP TRIGGER injected_result_failure") }
        let cold = ToolRuntime(store: f.store, registry: try ToolRegistry(tools: [f.tool]))
        try await RunRecovery(store: f.store, toolRuntime: cold).recover(runID: "r")
        #expect(try f.store.toolCall(id: call.id)?.state == .succeeded)
        #expect(try f.store.run(id: "r")?.state == .continuing)
        let after = try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") }
        #expect(after == before)
        #expect(try f.store.toolResult(toolCallID: call.id) != nil)
        #expect(try cold.confirmToolOutcome(toolCallID: call.id) == false)
        #expect(throws: (any Error).self) {
            try f.store.toolFileOperation(callID: call.id, attempt: 99, intentBinding: ToolIntentBinding.make(try #require(call.executionIntent)))
        }
        #expect(throws: (any Error).self) { try f.store.toolFileOperation(callID: call.id, attempt: call.attempt, intentBinding: "wrong") }
    }

    @Test func pendingSendAndBothPaneOwnersPreventToolRemoval() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: Data("leased".utf8), displayName: "leased.txt", in: f.store)
        let source = ConversationSession(conversationID: "source", configuration: nil)
        let secondary = ConversationSession(conversationID: "secondary", configuration: .init(
            providerInstanceID: .init(rawValue: "instance"), modelID: .init(rawValue: "model")))
        secondary.composer.draft.attachments = [.init(id: file.assetID, versionID: file.versionID,
            fingerprint: file.fingerprint, displayName: file.displayName, kind: .file)]
        f.sessions.retain(source, reconstruction: .history(configuration: nil))
        f.sessions.retain(secondary, reconstruction: .history(configuration: secondary.composer.configuration))
        f.sessions.activate(source)
        #expect(f.sessions.activate(secondary, alongside: source.conversationID))
        let first = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        #expect(try await f.approveAndExecute(first).failure == .resourceInUse)
        let coordinator = secondary.sendCoordinator(bridge: ComposerRuntimeActionBridge(
            start: { _ in "unused" }, stop: { _ in }, models: { _ in [] }, projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }), maxProviderSteps: 4)
        _ = try #require(coordinator.beginSend(capabilities: [.text, .streaming], quoteCommitReady: true,
            imageInputReady: false, fileInputReady: true, submissionID: "pending-tool-delete"))
        secondary.composer.draft.attachments = []
        let pending = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        #expect(try await f.approveAndExecute(pending).failure == .resourceInUse)
        coordinator.rejectSend(submissionID: "pending-tool-delete")
        let final = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        _ = try await f.approveAndExecute(final)
        #expect(try f.store.fileAsset(id: file.assetID) == nil)
        #expect(f.sessions.session(for: source.conversationID) === source)
        #expect(f.sessions.session(for: secondary.conversationID) === secondary)
    }

    @Test func cancellationBeforePublicationLeavesNoAssetOrReceipt() async throws {
        let cancellation = FileToolTaskCancellation()
        let f = try FileWriteFixture(observer: { _, phase in
            if phase == .protectedAfterWrite { cancellation.cancel() }
        })
        defer { f.cleanUp() }
        let call = try await f.prepare(["action": "create", "displayName": "cancel.txt", "content": "cancelled before publication"])
        try f.approve(call)
        let operation = Task { try await f.runtime.executeApproved(toolCallID: call.id) }
        cancellation.install(operation)
        do { _ = try await operation.value; Issue.record("Cancellation should escape") } catch is CancellationError { }
        #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") } == 0)
        #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM toolFileOperation") } == 0)
        #expect(try f.files.unreferencedBlobDigests(in: f.store).isEmpty)
        #expect(try f.store.toolCall(id: call.id)?.state == .indeterminate)
    }

    @Test func cancellationAtResultCommitCannotEraseTheCommittedFile() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let cancellation = FileToolTaskCancellation()
        try f.store.database.write { db in
            db.add(function: DatabaseFunction("cancel_completed_file_task", argumentCount: 0) { _ in
                cancellation.cancel(); return 0
            })
            try db.execute(sql: "CREATE TRIGGER cancel_after_file_commit BEFORE UPDATE OF state ON toolCall WHEN NEW.state = 'succeeded' BEGIN SELECT cancel_completed_file_task(); END")
        }
        let call = try await f.prepare(["action": "create", "displayName": "kept.txt", "content": "metadata wins"])
        try f.approve(call)
        let operation = Task { try await f.runtime.executeApproved(toolCallID: call.id) }
        cancellation.install(operation)
        _ = try await operation.value
        #expect(operation.isCancelled)
        #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") } == 1)
        #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM toolFileOperation") } == 1)
        #expect(try f.store.toolCall(id: call.id)?.state == .succeeded)
    }

    @Test func concurrentModifyAndDeleteCannotRemoveTheChangedVersion() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let file = try f.files.ingest(data: Data("old".utf8), displayName: "race.txt", in: f.store)
        let modify = try await f.prepare(["action": "modify", "assetID": file.assetID, "expectedVersionID": file.versionID, "content": "new"])
        let deletion = try await f.prepare(["action": "delete", "assetID": file.assetID, "expectedVersionID": file.versionID])
        try f.approve(modify); try f.approve(deletion)
        let writer = Task { try await f.runtime.executeApproved(toolCallID: modify.id) }
        let remover = Task { try await f.runtime.executeApproved(toolCallID: deletion.id) }
        _ = try await writer.value
        _ = try await remover.value
        let asset = try #require(try f.store.fileAsset(id: file.assetID))
        let version = try #require(try f.store.fileAssetVersion(id: asset.currentVersionID))
        #expect(version.id != file.versionID)
        #expect(try Data(contentsOf: f.files.blobURL(forFingerprint: version.contentFingerprint)) == Data("new".utf8))
        #expect(try f.store.toolCall(id: deletion.id)?.state.isTerminal == true)
    }

    @Test(arguments: [true, false])
    func conversationDeletionRetainsOnlyUncertainMinimalOperationProof(uncertain: Bool) async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let call = try await f.prepare(["action": "create", "displayName": "private-name.txt", "content": "private-body"])
        try f.approve(call)
        if uncertain {
            try f.store.database.write { try $0.execute(sql: "CREATE TRIGGER keep_uncertain BEFORE UPDATE OF state ON toolCall WHEN NEW.state = 'succeeded' BEGIN SELECT RAISE(ABORT, 'result fault'); END") }
        }
        do { _ = try await f.runtime.executeApproved(toolCallID: call.id) }
        catch { if !uncertain { throw error } }
        try f.store.transitionRun(id: "r", expectedState: .executingTools, to: .failed, endReason: .providerFailed)
        try f.store.beginDeletion(conversationID: "c")
        try f.store.finalizeDeletion(conversationID: "c")
        #expect(try f.store.toolCall(id: call.id) == nil)
        let count = try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM toolFileOperation") }
        #expect(count == (uncertain ? 1 : 0))
        if uncertain {
            let result = try f.store.database.read { try String.fetchOne($0, sql: "SELECT resultJSON FROM toolFileOperation") }
            #expect(result?.contains("private-body") == false)
            #expect(result?.contains("private-name") == false)
            #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM operationTombstone") } == 1)
        }
    }

    @Test func missingReceiptLeavesDispatchedWriteIndeterminate() async throws {
        let f = try FileWriteFixture()
        defer { f.cleanUp() }
        let call = try await f.prepare(["action": "create", "displayName": "unknown.txt", "content": "never replay"])
        try f.approve(call)
        let json = try #require(call.executionIntent)
        try f.store.markToolCallPrepared(id: call.id)
        _ = try f.store.dispatchToolCallWithPolicy(id: call.id, expectedAttempt: call.attempt,
            descriptor: f.tool.descriptor, safetyCap: .unrestricted, checkedIntentBinding: ToolIntentBinding.make(json), at: Date())
        try await RunRecovery(store: f.store, toolRuntime: f.runtime).recover(runID: "r")
        #expect(try f.store.toolCall(id: call.id)?.state == .indeterminate)
        #expect(try f.store.run(id: "r")?.endReason == .toolOutcomeUnknown)
        #expect(try f.store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM fileAsset") } == 0)
    }
}

@MainActor
private final class FileWriteFixture {
    let root: URL
    let store: PersistenceStore
    let files: ManagedFileStore
    let sessions = ConversationSessionStore()
    var tool: FilesTool { FilesTool(files: files, store: store, sessions: sessions) }
    var runtime: ToolRuntime { try! ToolRuntime(store: store, registry: ToolRegistry(tools: [tool])) }
    init(observer: (@Sendable (URL, ManagedFileTemporaryFilePhase) -> Void)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: "c", messageID: "m", runID: "r", runState: .executingTools))
        files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort, temporaryFileObserver: observer)
    }
    func prepare(_ args: [String: String]) async throws -> ToolCallRecord {
        _ = try await runtime.complete(agentRunID: "r", providerCallID: UUID().uuidString, toolID: "files",
            argumentsJSON: ToolArgumentJSON.normalizedObject(args), batchID: UUID().uuidString, batchSequence: 0)
        let call = try #require(try store.toolCalls(inRun: "r").last)
        try #require(call.state == .waitingForApproval)
        return call
    }
    func approve(_ call: ToolCallRecord) throws {
        try runtime.approve(toolCallID: call.id, displayedIntentBinding: ToolIntentBinding.make(try #require(call.executionIntent)))
    }
    func approveAndExecute(_ call: ToolCallRecord) async throws -> ToolExecutionResult {
        try approve(call)
        return try await runtime.executeApproved(toolCallID: call.id)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class FileToolTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ToolExecutionResult, Error>?
    func install(_ value: Task<ToolExecutionResult, Error>) { lock.lock(); task = value; lock.unlock() }
    func cancel() { lock.lock(); let current = task; lock.unlock(); current?.cancel() }
}
