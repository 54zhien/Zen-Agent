import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Attachment send")
@MainActor
struct AttachmentSendTests {
    @Test("attachmentCommitsWithMessageAndRunInOneTransaction")
    func attachmentCommitsWithMessageAndRunInOneTransaction() throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            protectionRequirement: .bestEffort
        )
        let descriptor = try managedFiles.ingest(
            data: Data("send with attachment".utf8),
            displayName: "scan.png",
            in: store
        )
        var commit = Fixtures.send(messageID: "message-with-attachment", runID: "run-with-attachment")
        commit.attachments = [MessageAttachmentRecord(
            id: "attachment-row-1",
            messageID: "message-with-attachment",
            assetID: descriptor.assetID,
            versionID: descriptor.versionID,
            sequence: 0
        )]

        try store.commitUserTurnAndCreateParentRun(commit)

        #expect(try store.messages(inConversation: "c1").map(\.id) == ["message-with-attachment"])
        #expect(try store.run(id: "run-with-attachment")?.triggerMessageID
            == "message-with-attachment")
        let savedAttachments = try store.attachments(forMessage: "message-with-attachment")
        #expect(savedAttachments.count == 1)
        #expect(savedAttachments.first?.assetID == descriptor.assetID)
        #expect(savedAttachments.first?.versionID == descriptor.versionID)
        #expect(savedAttachments.first?.sequence == 0)
    }

    @Test("failedAttachmentCommitRollsBackMessageAndRun")
    func failedAttachmentCommitRollsBackMessageAndRun() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        var commit = Fixtures.send(messageID: "message-rollback", runID: "run-rollback")
        commit.attachments = [MessageAttachmentRecord(
            id: "attachment-invalid-version",
            messageID: "message-rollback",
            assetID: "missing-asset",
            versionID: "missing-version",
            sequence: 0
        )]

        var failure: Error?
        do {
            try store.commitUserTurnAndCreateParentRun(commit)
        } catch {
            failure = error
        }

        #expect(failure != nil)
        #expect(try store.conversation(id: "c1") == nil)
        #expect(try store.messages(inConversation: "c1").isEmpty)
        #expect(try store.run(id: "run-rollback") == nil)
        #expect(try store.attachments(forMessage: "message-rollback").isEmpty)
        let partCount = try store.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messagePart WHERE messageID = ?",
                arguments: ["message-rollback"]
            ) ?? 0
        }
        #expect(partCount == 0)
    }

    @Test("submissionDigestRejectsChangedAttachmentPayloadOrOrder")
    func submissionDigestRejectsChangedAttachmentPayloadOrOrder() async throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let runtimeFixture = try makeRuntimeFixture(supportRoot: supportRoot)
        let first = try runtimeFixture.managedFiles.ingest(
            data: Data("first".utf8), displayName: "first.txt", in: runtimeFixture.store
        )
        let second = try runtimeFixture.managedFiles.ingest(
            data: Data("second".utf8), displayName: "second.txt", in: runtimeFixture.store
        )
        let third = try runtimeFixture.managedFiles.ingest(
            data: Data("third".utf8), displayName: "third.txt", in: runtimeFixture.store
        )
        var command = I05RuntimeTestFixtures.command(text: "compare these")
        command.submissionID = "attachment-digest-stable-id"
        command.attachments = [sendAttachment(for: first), sendAttachment(for: second)]

        let originalRunID = try await runtimeFixture.runtime.start(command)
        let replayedRunID = try await runtimeFixture.runtime.start(command)
        #expect(replayedRunID == originalRunID)

        var changedIdentity = command
        changedIdentity.attachments[0] = sendAttachment(for: third)
        await expectSubmissionConflict(changedIdentity, in: runtimeFixture.runtime)

        var changedOrder = command
        changedOrder.attachments.reverse()
        await expectSubmissionConflict(changedOrder, in: runtimeFixture.runtime)

        #expect(try runtimeFixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .user }.count == 1)
        try await runtimeFixture.runtime.waitForCompletion(runID: originalRunID)
    }

    @Test("acceptedSendClearsOnlyCapturedAttachments")
    func acceptedSendClearsOnlyCapturedAttachments() {
        let captured = attachmentReference(
            assetID: "asset-captured",
            versionID: "version-captured",
            hex: "a",
            name: "captured.pdf"
        )
        let addedWhileSending = attachmentReference(
            assetID: "asset-new",
            versionID: "version-new",
            hex: "b",
            name: "new.pdf"
        )
        let editedWhileSending = attachmentReference(
            assetID: "asset-captured",
            versionID: "version-next",
            hex: "c",
            name: "captured-updated.pdf"
        )
        let (controller, coordinator) = makeCoordinator(attachments: [captured])
        let command = coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: true,
            fileInputReady: true,
            submissionID: "accepted-attachment-send"
        )
        #expect(command?.attachments == [sendAttachment(for: captured)])
        controller.draft.attachments = [
            captured,
            addedWhileSending,
            editedWhileSending,
            captured,
        ]

        coordinator.acceptSend(
            submissionID: "accepted-attachment-send",
            projection: RunProjection(runID: "accepted-attachment-run", state: .preparing)
        )

        #expect(controller.draft.attachments == [
            addedWhileSending,
            editedWhileSending,
            captured,
        ])
    }

    @Test("rejectedSendRetainsAttachments")
    func rejectedSendRetainsAttachments() {
        let attachments = [
            attachmentReference(
                assetID: "asset-one", versionID: "version-one", hex: "a", name: "one.pdf"
            ),
            attachmentReference(
                assetID: "asset-two", versionID: "version-two", hex: "b", name: "two.pdf"
            ),
        ]
        let (controller, coordinator) = makeCoordinator(attachments: attachments)
        #expect(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: true,
            fileInputReady: true,
            submissionID: "rejected-attachment-send"
        ) != nil)

        coordinator.rejectSend(submissionID: "rejected-attachment-send")

        #expect(controller.draft.attachments == attachments)
        #expect(coordinator.submission == .idle)
    }

    @Test("attachmentIdentityCarriesVersionAndFingerprintWithoutBytes")
    func attachmentIdentityCarriesVersionAndFingerprintWithoutBytes() throws {
        let fingerprint = "sha256:\(String(repeating: "a", count: 64))"
        let reference = AttachmentReference(
            id: "asset-1",
            versionID: "version-1",
            fingerprint: fingerprint,
            displayName: "scan.png",
            kind: .image
        )
        let sendAttachment = SendAttachment(
            assetID: reference.id,
            versionID: reference.versionID,
            fingerprint: reference.fingerprint,
            kind: reference.kind,
            displayName: reference.displayName
        )

        #expect(reference.versionID == "version-1")
        #expect(reference.fingerprint == fingerprint)
        #expect(Mirror(reflecting: reference).children.compactMap(\.label)
            == ["id", "versionID", "fingerprint", "displayName", "kind"])
        #expect(Mirror(reflecting: sendAttachment).children.compactMap(\.label)
            == ["assetID", "versionID", "fingerprint", "kind", "displayName"])

        let root = try #require(repositoryRoot())
        let sourceURL = root.appendingPathComponent("App/Conversation/ComposerAttachment.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let declarationStart = try #require(source.range(of: "struct AttachmentReference {"))
        let declarationEnd = try #require(source[declarationStart.lowerBound...].firstIndex(of: "}"))
        let declaration = source[declarationStart.lowerBound...declarationEnd]
        for forbidden in ["Data", "URL", "bytes", "content"] {
            #expect(!declaration.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test("ingestRejectsMismatchedAssetVersionOrFingerprint")
    func ingestRejectsMismatchedAssetVersionOrFingerprint() async throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let runtimeFixture = try makeRuntimeFixture(supportRoot: supportRoot)
        let descriptor = try runtimeFixture.managedFiles.ingest(
            data: Data("identity check".utf8),
            displayName: "identity.txt",
            in: runtimeFixture.store
        )
        var command = I05RuntimeTestFixtures.command(text: "do not commit bad identity")
        command.submissionID = "mismatched-attachment-identity"
        let valid = sendAttachment(for: descriptor)

        let wrongVersion = SendAttachment(
            assetID: valid.assetID,
            versionID: "forged-version",
            fingerprint: valid.fingerprint,
            kind: valid.kind,
            displayName: valid.displayName
        )
        command.attachments = [wrongVersion]
        await expectFailureStarting(command, in: runtimeFixture.runtime)

        let wrongAsset = SendAttachment(
            assetID: "forged-asset",
            versionID: valid.versionID,
            fingerprint: valid.fingerprint,
            kind: valid.kind,
            displayName: valid.displayName
        )
        command.submissionID = "mismatched-attachment-asset"
        command.attachments = [wrongAsset]
        await expectFailureStarting(command, in: runtimeFixture.runtime)

        let wrongFingerprint = SendAttachment(
            assetID: valid.assetID,
            versionID: valid.versionID,
            fingerprint: "sha256:\(String(repeating: "f", count: 64))",
            kind: valid.kind,
            displayName: valid.displayName
        )
        command.submissionID = "mismatched-attachment-fingerprint"
        command.attachments = [wrongFingerprint]
        await expectFailureStarting(command, in: runtimeFixture.runtime)

        #expect(try runtimeFixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).isEmpty)
        #expect(try runtimeFixture.store.run(submissionID: "mismatched-attachment-identity") == nil)
        #expect(try runtimeFixture.store.run(submissionID: "mismatched-attachment-asset") == nil)
        #expect(try runtimeFixture.store.run(submissionID: "mismatched-attachment-fingerprint") == nil)

        command.submissionID = "valid-attachment-load-source"
        command.attachments = [valid]
        let runID = try await runtimeFixture.runtime.start(command)
        try await runtimeFixture.runtime.waitForCompletion(runID: runID)
        let messageID = try #require(runtimeFixture.store.run(id: runID)?.triggerMessageID)
        let loadedBytes = try await runtimeFixture.runtime.loadAttachmentContent(
            valid,
            forMessageID: messageID
        )
        #expect(loadedBytes == Data("identity check".utf8))
        for invalidAttachment in [wrongAsset, wrongVersion, wrongFingerprint] {
            do {
                _ = try await runtimeFixture.runtime.loadAttachmentContent(
                    invalidAttachment,
                    forMessageID: messageID
                )
                #expect(false, "loading must reject an identity that differs from the committed version")
            } catch {
                #expect(error is ConversationRuntimeError || error is ManagedFileStoreError)
            }
        }
        #expect(try runtimeFixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .user }.count == 1)
    }

    @Test("existingSubmissionRetryWithCorruptBlobFailsClosed")
    func existingSubmissionRetryWithCorruptBlobFailsClosed() async throws {
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let runtimeFixture = try makeRuntimeFixture(supportRoot: supportRoot)
        let descriptor = try runtimeFixture.managedFiles.ingest(
            data: Data("valid on first send".utf8),
            displayName: "retry.txt",
            in: runtimeFixture.store
        )
        var command = I05RuntimeTestFixtures.command(text: "retry safely")
        command.submissionID = "corrupt-attachment-retry"
        command.attachments = [sendAttachment(for: descriptor)]
        let originalRunID = try await runtimeFixture.runtime.start(command)
        try await runtimeFixture.runtime.waitForCompletion(runID: originalRunID)

        try FileManager.default.removeItem(
            at: try runtimeFixture.managedFiles.blobURL(forFingerprint: descriptor.fingerprint)
        )
        var retryFailure: Error?
        do {
            _ = try await runtimeFixture.runtime.start(command)
        } catch {
            retryFailure = error
        }

        #expect(retryFailure is ManagedFileStoreError)
        #expect(try runtimeFixture.store.run(submissionID: command.submissionID)?.id == originalRunID)
        #expect(try runtimeFixture.store.messages(
            inConversation: I05RuntimeTestFixtures.conversationID
        ).filter { $0.role == .user }.count == 1)
    }

    private func makeRuntimeFixture(supportRoot: URL) throws -> (
        store: PersistenceStore,
        runtime: ConversationRuntime,
        managedFiles: ManagedFileStore
    ) {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            protectionRequirement: .bestEffort
        )
        let provider = FakeProvider(
            id: .deepSeek,
            instanceID: fixture.instance.id,
            modelNames: [I05RuntimeTestFixtures.modelID.rawValue],
            capabilities: [.text, .streaming],
            scriptedEvents: [.finish(.stop)]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            managedFileStore: managedFiles
        )
        return (fixture.store, runtime, managedFiles)
    }

    private func expectSubmissionConflict(
        _ command: SendCommand,
        in runtime: ConversationRuntime
    ) async {
        do {
            _ = try await runtime.start(command)
            #expect(false, "reusing a submission id with changed attachment input must fail")
        } catch let error as ConversationRuntimeError {
            #expect(error == .submissionIDPayloadConflict(command.submissionID))
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    private func expectFailureStarting(_ command: SendCommand, in runtime: ConversationRuntime) async {
        do {
            _ = try await runtime.start(command)
            #expect(false, "invalid attachment identity must not be committed")
        } catch {
            #expect(error is ManagedFileStoreError)
        }
    }

    private func makeCoordinator(
        attachments: [AttachmentReference]
    ) -> (ComposerController, ComposerSendCoordinator) {
        let providerInstanceID = ProviderInstanceID(rawValue: "attachment-test-instance")
        let modelID = ModelID(rawValue: "attachment-test-model")
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in "accepted-attachment-run" },
            stop: { _ in },
            models: { _ in [] },
            projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: providerInstanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: "send attached files",
                selection: ComposerSelection(range: 0..<19),
                references: [],
                attachments: attachments,
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "attachment-test-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 2
        )
        return (controller, coordinator)
    }

    private func attachmentReference(
        assetID: String,
        versionID: String,
        hex: String,
        name: String
    ) -> AttachmentReference {
        AttachmentReference(
            id: assetID,
            versionID: versionID,
            fingerprint: "sha256:\(String(repeating: hex, count: 64))",
            displayName: name,
            kind: .file
        )
    }

    private func sendAttachment(for reference: AttachmentReference) -> SendAttachment {
        SendAttachment(
            assetID: reference.id,
            versionID: reference.versionID,
            fingerprint: reference.fingerprint,
            kind: reference.kind,
            displayName: reference.displayName
        )
    }

    private func sendAttachment(for descriptor: ManagedFileDescriptor) -> SendAttachment {
        SendAttachment(
            assetID: descriptor.assetID,
            versionID: descriptor.versionID,
            fingerprint: descriptor.fingerprint,
            kind: .file,
            displayName: descriptor.displayName
        )
    }

    private func temporarySupportRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentSend-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        for _ in 0..<8 {
            var appIsDirectory: ObjCBool = false
            let hasApp = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("App", isDirectory: true).path,
                isDirectory: &appIsDirectory
            ) && appIsDirectory.boolValue
            var testsIsDirectory: ObjCBool = false
            let hasTests = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Tests", isDirectory: true).path,
                isDirectory: &testsIsDirectory
            ) && testsIsDirectory.boolValue
            if hasApp && hasTests { return directory }

            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }

        return nil
    }
}
