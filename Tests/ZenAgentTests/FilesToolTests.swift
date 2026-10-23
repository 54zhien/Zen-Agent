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
