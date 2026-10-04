import Foundation
import Testing
@testable import ZenAgent

@Suite("Files retained Session protection")
@MainActor
struct FilesSessionProtectionTests {
    @Test("the actual pending send snapshot refuses reserved managed-file removal")
    func pendingSendProtectsBytesThroughTheComposedRemovalPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = PersistenceStore(database: try ZenDatabase.inMemory())
        let files = ManagedFileStore(applicationSupportRoot: root, protectionRequirement: .bestEffort)
        let bytes = Data("pending real managed bytes".utf8)
        let descriptor = try await Task.detached {
            try files.ingest(data: bytes, displayName: "pending.txt", in: persistence)
        }.value
        let sessions = ConversationSessionStore(warmLimit: 0)
        let pending = session("managed-pending", asset: nil)
        pending.composer.draft.attachments = [AttachmentReference(id: descriptor.assetID,
            versionID: descriptor.versionID, fingerprint: descriptor.fingerprint,
            displayName: descriptor.displayName, kind: .file)]
        sessions.retain(pending, reconstruction: .history(configuration: pending.composer.configuration))
        sessions.activate(pending)
        let coordinator = pending.sendCoordinator(bridge: ComposerRuntimeActionBridge(
            start: { _ in "unused" }, stop: { _ in }, models: { _ in [] }, projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }), maxProviderSteps: 4)
        _ = try #require(coordinator.beginSend(capabilities: [.text, .streaming],
            quoteCommitReady: true, imageInputReady: false, fileInputReady: true, submissionID: "managed-send"))
        pending.composer.draft.attachments = []
        let replacement = session("replacement", asset: nil)
        sessions.retain(replacement, reconstruction: .history(configuration: replacement.composer.configuration))
        sessions.activate(replacement)
        sessions.evictIfNeeded(isRuntimeProtected: { _ in false })
        let remove = { @Sendable in
            try await Task.detached {
                try files.removeUnreferencedAsset(id: descriptor.assetID, in: persistence, protectedAssetIDs: [])
            }.value
        }
        #expect(try await sessions.withFileRemovalReservation(assetID: descriptor.assetID, operation: remove) == false)
        #expect(try persistence.fileAsset(id: descriptor.assetID) != nil)
        let blob = try files.blobURL(forFingerprint: descriptor.fingerprint)
        #expect(try Data(contentsOf: blob) == bytes)
        coordinator.rejectSend(submissionID: "stale")
        #expect(try await sessions.withFileRemovalReservation(assetID: descriptor.assetID, operation: remove) == false)
        coordinator.rejectSend(submissionID: "managed-send")
        #expect(try await sessions.withFileRemovalReservation(assetID: descriptor.assetID, operation: remove))
        #expect(try persistence.fileAsset(id: descriptor.assetID) == nil)
        #expect(!FileManager.default.fileExists(atPath: blob.path))
    }

    @Test("caller cancellation retains the reservation until its actual writer exits")
    func cancelledCallerCannotReleaseABlockedWriterReservation() async throws {
        let store = ConversationSessionStore()
        let gate = FileRemovalReservationGate()
        let removal = Task {
            try await store.withFileRemovalReservation(assetID: "cancelled-file") {
                let writer = Task.detached {
                    await gate.hold()
                    try Task.checkCancellation()
                    return true
                }
                return try await withTaskCancellationHandler {
                    try await writer.value
                } onCancel: { writer.cancel() }
            }
        }
        await gate.waitUntilEntered()
        removal.cancel()
        let duplicate = try await store.withFileRemovalReservation(assetID: "cancelled-file") {
            Issue.record("cancelled caller released the reservation before its writer exited")
            return true
        }
        #expect(!duplicate)
        await gate.release()
        do {
            _ = try await removal.value
            Issue.record("cancelled writer should throw")
        } catch is CancellationError {}
        #expect(try await store.withFileRemovalReservation(assetID: "cancelled-file") { true })
    }

    @Test("a removal reservation spans the entire asynchronous writer operation")
    func reservationCannotBeReenteredAndAlwaysReleases() async throws {
        let store = ConversationSessionStore()
        let gate = FileRemovalReservationGate()
        let removal = Task {
            try await store.withFileRemovalReservation(assetID: "reserved-file") {
                await gate.hold()
                return true
            }
        }
        await gate.waitUntilEntered()
        let duplicate = try await store.withFileRemovalReservation(assetID: "reserved-file") {
            Issue.record("duplicate removal entered the writer")
            return true
        }
        #expect(!duplicate)
        await gate.release()
        #expect(try await removal.value)
        let reacquired = try await store.withFileRemovalReservation(assetID: "reserved-file") { true }
        #expect(reacquired)
        do {
            _ = try await store.withFileRemovalReservation(assetID: "reserved-file") {
                throw CancellationError()
            }
            Issue.record("cancelled removal should throw")
        } catch is CancellationError {}
        #expect(try await store.withFileRemovalReservation(assetID: "reserved-file") { true })
    }

    @Test func bothPanesAndWarmDraftsProtectTheirAttachments() {
        let store = ConversationSessionStore(warmLimit: 0)
        let warm = session("warm", asset: "warm-file")
        let source = session("source", asset: "source-file")
        let secondary = session("secondary", asset: "secondary-file")
        for item in [warm, source, secondary] {
            store.retain(item, reconstruction: .history(configuration: item.composer.configuration))
        }
        store.activate(warm)
        store.activate(source)
        #expect(store.activate(secondary, alongside: "source"))
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.protectedFileAssetIDs == ["warm-file", "source-file", "secondary-file"])
        #expect(store.session(for: "warm") === warm)
    }

    @Test("only matching submission completion releases a detached attachment snapshot",
          arguments: [true, false])
    func pendingSnapshotSurvivesDraftReplacementAndWarmNavigation(accepted: Bool) throws {
        let store = ConversationSessionStore(warmLimit: 0)
        let pending = session("pending", asset: "submitted-file")
        let bridge = ComposerRuntimeActionBridge(start: { _ in "run" }, stop: { _ in },
            models: { _ in [] }, projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } })
        let coordinator = pending.sendCoordinator(bridge: bridge, maxProviderSteps: 4)
        let command = try #require(coordinator.beginSend(capabilities: [.text, .streaming],
            quoteCommitReady: true, imageInputReady: false, fileInputReady: true,
            submissionID: "pending-submission"))
        pending.composer.draft.attachments = [attachment("later-file")]
        store.retain(pending, reconstruction: .history(configuration: pending.composer.configuration))
        store.activate(pending)
        let other = session("other", asset: nil)
        store.retain(other, reconstruction: .history(configuration: other.composer.configuration))
        store.activate(other)
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.protectedFileAssetIDs == ["submitted-file", "later-file"])
        coordinator.rejectSend(submissionID: "stale-submission")
        #expect(store.protectedFileAssetIDs.contains("submitted-file"))
        if accepted {
            coordinator.acceptSend(submissionID: command.submissionID,
                projection: RunProjection(runID: "accepted-run", state: .preparing))
        } else {
            coordinator.rejectSend(submissionID: command.submissionID)
        }
        #expect(store.protectedFileAssetIDs == ["later-file"])
        #expect(pending.composer.draft.attachments == [attachment("later-file")])
    }

    private func session(_ id: String, asset: String?) -> ConversationSession {
        let item = ConversationSession(conversationID: id,
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "instance"),
                modelID: ModelID(rawValue: "model")))
        if let asset { item.composer.draft.attachments = [attachment(asset)] }
        return item
    }

    private func attachment(_ id: String) -> AttachmentReference {
        AttachmentReference(id: id, versionID: "version-\(id)", fingerprint: "hash-\(id)",
            displayName: id, kind: .file)
    }
}

private actor FileRemovalReservationGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
