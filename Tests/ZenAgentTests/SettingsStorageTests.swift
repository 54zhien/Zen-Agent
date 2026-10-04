import Foundation
import Testing
@testable import ZenAgent

@Suite("Settings storage ownership")
@MainActor
struct SettingsStorageTests {
    @Test("clear cache preserves a leased native copy and the immutable managed bytes")
    func cacheCleanupPreservesTheActiveCopyAndManagedAsset() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root,
            protectionRequirement: .bestEffort, presentationCacheRoot: cache)
        let data = Data("retained managed fixture".utf8)
        let asset = try files.ingest(data: data, displayName: "retained.txt", mediaType: "text/plain", in: store)
        let attachment = SendAttachment(assetID: asset.assetID, versionID: asset.versionID,
            fingerprint: asset.fingerprint, kind: .file, displayName: asset.displayName)
        let copy = try files.makePresentationCopy(for: attachment, in: store)
        let model = SettingsStorageModel(store: store, files: files)
        await model.refresh()
        #expect(model.footprint?.managedBytes == Int64(data.count))
        #expect(model.footprint?.cacheBytes == Int64(data.count))
        #expect(model.footprint?.databaseBytes == nil,
                "An in-memory store must not claim zero disk bytes for a real database")

        await model.clearCache()

        #expect(try Data(contentsOf: copy.url) == data)
        #expect(try files.loadVerifiedBlob(for: attachment, in: store) == data)
        #expect(model.footprint?.cacheBytes == Int64(data.count))
        #expect(model.errorMessage == nil)
        withExtendedLifetime(copy) {}
    }
}
