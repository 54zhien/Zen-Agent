import Foundation
import Testing

@testable import ZenAgent

private actor ImageInputRequestLedger {
    private var values: [ProviderChatRequest] = []

    func append(_ request: ProviderChatRequest) { values.append(request) }
    func requests() -> [ProviderChatRequest] { values }
}

private struct ImageInputTestProvider: ModelProvider {
    static let primaryModelID = ModelID(rawValue: "main-text")
    static let imageModelID = ModelID(rawValue: "image-vision")
    static let visionModelID = ModelID(rawValue: "main-vision")

    let ledger: ImageInputRequestLedger
    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "image-input-runtime-test.v1" }
    var adapterPromptInstructions: String { "Preserve the test request." }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [
            ModelDescriptor(
                id: Self.primaryModelID,
                providerInstanceID: instance.id,
                displayName: "Main text model",
                capabilities: [.text, .streaming]
            ),
            ModelDescriptor(
                id: Self.imageModelID,
                providerInstanceID: instance.id,
                displayName: "Image model",
                capabilities: [.vision]
            ),
            ModelDescriptor(
                id: Self.visionModelID,
                providerInstanceID: instance.id,
                displayName: "Main vision model",
                capabilities: [.text, .streaming, .vision]
            ),
        ]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown test model")
        }
        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            resolvedEndpoint: URL(
                string: "https://runtime-user:runtime-pass@image-runtime.example/v1/\(modelID.rawValue)?token=runtime-secret#private"
            )!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        _ = seed
        _ = credentials
        await ledger.append(request)
        let text = request.modelID == Self.imageModelID
            ? "A red bicycle is visible."
            : "The image shows a red bicycle."
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.finish(.stop))
            continuation.finish()
        }
    }
}

private struct ImageInputRuntimeFixture {
    let supportRoot: URL
    let store: PersistenceStore
    let credentials: CredentialStore
    let instance: ProviderInstance
    let files: ManagedFileStore
    let image: ManagedFileDescriptor
    let provider: ImageInputTestProvider

    static func make() throws -> Self {
        let supportRoot = URL.temporaryDirectory
            .appending(path: "zen-image-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let reference = CredentialReference(id: "image-input-runtime-credential")
        try credentials.provision(SecretValue("image-input-test-secret"), as: reference)
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "image-input-runtime-instance"),
            providerID: .deepSeek,
            displayName: "Image Runtime Account",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: reference
        )
        try store.createProviderInstance(instance)
        try store.database.write { db in try Fixtures.conversation().insert(db) }
        let files = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            protectionRequirement: .bestEffort
        )
        let image = try files.ingest(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
            displayName: "scan.png",
            mediaType: "image/png",
            in: store
        )
        return Self(
            supportRoot: supportRoot,
            store: store,
            credentials: credentials,
            instance: instance,
            files: files,
            image: image,
            provider: ImageInputTestProvider(ledger: ImageInputRequestLedger())
        )
    }

    func removeFiles() { try? FileManager.default.removeItem(at: supportRoot) }

    func seed(for modelID: ModelID) throws -> RequestConfigSeed {
        let metadata = try #require(try credentials.metadata(for: #require(instance.credentialReference)))
        return try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: CredentialBindingSnapshot(
                reference: metadata.reference,
                generation: metadata.bindingGeneration
            )
        )
    }

    var sendAttachment: SendAttachment {
        SendAttachment(
            assetID: image.assetID,
            versionID: image.versionID,
            fingerprint: image.fingerprint,
            kind: .image,
            displayName: image.displayName
        )
    }

    func snapshot(maxProviderSteps: Int = 1) -> RunExecutionSnapshot {
        RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: "runtime-safety-v1",
                zenCore: "zen-core-v1",
                providerAdapterInstructions: provider.adapterPromptInstructions
            ),
            modelCapabilities: [.text, .streaming],
            exposedTools: [],
            maxProviderSteps: maxProviderSteps
        )
    }
}

@Suite("Image input runtime")
struct ImageInputRuntimeTests {
    @Test("an explicit slot selects the one-request vision route or preprocessing route")
    func explicitTargetSelectsFrozenRoute() throws {
        let fixture = try ImageInputRuntimeFixture.make()
        defer { fixture.removeFiles() }
        let registry = ModelProviderRegistry(provider: fixture.provider)
        let mainVision = ImageInputTarget(
            providerInstanceID: fixture.instance.id,
            modelID: ImageInputTestProvider.visionModelID
        )
        let separateTarget = ImageInputTarget(
            providerInstanceID: fixture.instance.id,
            modelID: ImageInputTestProvider.imageModelID
        )

        let missing = try ImageInputTargetResolver.presentation(
            target: nil,
            primaryTarget: mainVision,
            primaryCapabilities: [.text, .streaming, .vision],
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        #expect(missing.availability == .requiresSelection)
        #expect(missing.route == nil)

        let direct = try ImageInputTargetResolver.resolve(
            target: mainVision,
            primaryTarget: mainVision,
            primaryCapabilities: [.text, .streaming, .vision],
            primarySeed: try fixture.seed(for: ImageInputTestProvider.visionModelID),
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        #expect(direct.route == .primaryVision)

        let preprocessing = try ImageInputTargetResolver.resolve(
            target: separateTarget,
            primaryTarget: ImageInputTarget(
                providerInstanceID: fixture.instance.id,
                modelID: ImageInputTestProvider.primaryModelID
            ),
            primaryCapabilities: [.text, .streaming],
            primarySeed: try fixture.seed(for: ImageInputTestProvider.primaryModelID),
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        #expect(preprocessing.route == .preprocess)

        let presentation = try ImageInputTargetResolver.presentation(
            target: separateTarget,
            primaryTarget: ImageInputTarget(
                providerInstanceID: fixture.instance.id,
                modelID: ImageInputTestProvider.primaryModelID
            ),
            primaryCapabilities: [.text, .streaming],
            store: fixture.store,
            providerRegistry: registry,
            credentials: fixture.credentials
        )
        #expect(presentation.availability == .ready)
        #expect(presentation.route == .preprocess)
        #expect(presentation.accountName == "Image Runtime Account")
        #expect(presentation.providerName == "DeepSeek")
        #expect(presentation.modelName == "Image model")
        #expect(presentation.endpointDisplay == "https://image-runtime.example/v1/image-vision")
    }

    @Test("Send freezes the explicit target, reuses image analysis, and excludes it from the model step limit")
    func sendPreprocessesImageAndPersistsItsSourceForThePrimaryModel() async throws {
        let fixture = try ImageInputRuntimeFixture.make()
        defer { fixture.removeFiles() }
        let target = ImageInputTarget(
            providerInstanceID: fixture.instance.id,
            modelID: ImageInputTestProvider.imageModelID
        )
        let command = SendCommand(
            conversationID: "c1",
            text: "What is in this picture?",
            attachments: [fixture.sendAttachment],
            imageInputTarget: target,
            providerInstanceID: fixture.instance.id,
            modelID: ImageInputTestProvider.primaryModelID,
            maxProviderSteps: 1,
            submissionID: "image-input-runtime-send"
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            providerRegistry: ModelProviderRegistry(provider: fixture.provider),
            credentials: fixture.credentials,
            managedFileStore: fixture.files
        )
        let runID = try await runtime.start(command)
        #expect(try await runtime.start(command) == runID)
        try await runtime.waitForCompletion(runID: runID)

        let run = try #require(try fixture.store.run(id: runID))
        #expect(run.imageInputSeed?.route == .preprocess)
        #expect(run.imageInputSeed?.requestConfigSeed.modelID == ImageInputTestProvider.imageModelID)
        #expect(run.imageInputSeed?.imageVersionIDs == [fixture.image.versionID])
        #expect(run.imageInputSeed?.submissionDigest == run.submissionDigest)
        #expect(run.state == .completed)

        let requests = await fixture.provider.ledger.requests()
        #expect(requests.map(\.modelID) == [
            ImageInputTestProvider.imageModelID,
            ImageInputTestProvider.primaryModelID,
        ])
        if case .userContent(let parts)? = requests.first?.messages.last {
            #expect(parts.contains(where: { if case .image = $0 { true } else { false } }))
        } else {
            #expect(Bool(false), "the Image Input request must carry the committed image bytes")
        }
        if case .user(let text)? = requests.last?.messages.last {
            #expect(text.contains("Source: scan.png"))
            #expect(text.contains("A red bicycle is visible."))
        } else {
            #expect(Bool(false), "the primary request must receive source-labelled image context")
        }

        let imageResult = try #require(try fixture.store.completedImageInputResult(
            runID: runID,
            messageID: #require(run.triggerMessageID),
            versionID: fixture.image.versionID
        ))
        #expect(imageResult.internalContext.contains("Source: scan.png"))
        #expect(imageResult.targetEndpoint == "https://image-runtime.example/v1/image-vision")
        #expect(try fixture.store.steps(inRun: runID, purpose: .imageInput).count == 1)
        #expect(try fixture.store.steps(inRun: runID, purpose: .modelResponse).count == 1)

        var changedTarget = command
        changedTarget.imageInputTarget = ImageInputTarget(
            providerInstanceID: fixture.instance.id,
            modelID: ImageInputTestProvider.visionModelID
        )
        do {
            _ = try await runtime.start(changedTarget)
            #expect(Bool(false), "a changed slot target must conflict with the frozen submission digest")
        } catch let error as ConversationRuntimeError {
            #expect(error == .submissionIDPayloadConflict(command.submissionID))
        }
    }

    @Test("recovery reuses completed preprocessing and does not resend an uncertain image attempt")
    func recoveryReusesSavedImageAndRefusesUnknownDispatch() async throws {
        let fixture = try ImageInputRuntimeFixture.make()
        defer { fixture.removeFiles() }
        let primarySeed = try fixture.seed(for: ImageInputTestProvider.primaryModelID)
        let imageSeed = try fixture.seed(for: ImageInputTestProvider.imageModelID)
        let submissionDigest = String(repeating: "a", count: 64)
        let frozenImageSeed = ImageInputExecutionSeed(
            providerID: fixture.provider.id,
            adapterRevision: fixture.provider.adapterRevision,
            requestConfigSeed: imageSeed,
            capabilities: [.vision],
            imageVersionIDs: [fixture.image.versionID],
            submissionDigest: submissionDigest,
            route: .preprocess
        )
        var commit = Fixtures.send(messageID: "user-image-recovery", runID: "run-image-recovery")
        commit.attachments = [MessageAttachmentRecord(
            id: "attachment-image-recovery",
            messageID: "user-image-recovery",
            assetID: fixture.image.assetID,
            versionID: fixture.image.versionID,
            sequence: 0
        )]
        commit.run.requestConfigSeed = primarySeed
        commit.run.submissionDigest = submissionDigest
        commit.imageInputSeed = frozenImageSeed
        try fixture.store.commitUserTurnAndCreateParentRun(commit)
        let snapshot = fixture.snapshot()
        try fixture.store.completeExecutionSnapshot(
            runID: "run-image-recovery",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try fixture.store.transitionRun(
            id: "run-image-recovery",
            expectedState: .preparing,
            to: .requestingModel
        )
        let completedAttempt = AgentStepRecord(
            stepID: "image-input-run-image-recovery-\(fixture.image.versionID)",
            runID: "run-image-recovery",
            sequence: 0,
            attempt: 1,
            createdAt: Fixtures.epoch,
            purpose: .imageInput
        )
        try fixture.store.recordStep(completedAttempt)
        #expect(try fixture.store.markImageInputStepStarted(
            runID: completedAttempt.runID,
            identity: completedAttempt.attemptIdentity
        ))
        #expect(try fixture.store.completeImageInput(
            ImageInputResultRecord(
                runID: completedAttempt.runID,
                messageID: "user-image-recovery",
                versionID: fixture.image.versionID,
                internalContext: ImageInputRuntime.internalContext(
                    sourceName: fixture.image.displayName,
                    analysis: "A red bicycle is visible."
                ),
                targetProvenance: ImageInputRuntime.provenance(for: frozenImageSeed),
                completedAt: Fixtures.epoch.addingTimeInterval(1)
            ),
            runID: completedAttempt.runID,
            identity: completedAttempt.attemptIdentity
        ))
        try await RunRecovery(store: fixture.store, credentials: fixture.credentials)
            .recover(runID: "run-image-recovery")
        #expect(try fixture.store.run(id: "run-image-recovery")?.state == .requestingModel)
        let runtime = AgentRuntime(
            store: fixture.store,
            provider: fixture.provider,
            credentials: fixture.credentials,
            managedFileStore: fixture.files
        )
        let request = ProviderChatRequest(
            modelID: ImageInputTestProvider.primaryModelID,
            messages: [.user("What is in this picture?")]
        )
        let stream = await runtime.advance(
            runID: "run-image-recovery",
            request: request,
            snapshot: snapshot
        )
        for try await _ in stream {}
        let requests = await fixture.provider.ledger.requests()
        #expect(requests.map(\.modelID) == [ImageInputTestProvider.primaryModelID])
        #expect(try fixture.store.steps(inRun: "run-image-recovery", purpose: .imageInput).count == 1)
        #expect(try fixture.store.run(id: "run-image-recovery")?.state == .completed)

        var uncertainCommit = Fixtures.send(messageID: "user-image-unknown", runID: "run-image-unknown")
        uncertainCommit.attachments = [MessageAttachmentRecord(
            id: "attachment-image-unknown",
            messageID: "user-image-unknown",
            assetID: fixture.image.assetID,
            versionID: fixture.image.versionID,
            sequence: 0
        )]
        uncertainCommit.run.requestConfigSeed = primarySeed
        uncertainCommit.run.submissionDigest = String(repeating: "b", count: 64)
        var unknownSeed = frozenImageSeed
        unknownSeed.submissionDigest = String(repeating: "b", count: 64)
        uncertainCommit.imageInputSeed = unknownSeed
        try fixture.store.commitUserTurnAndCreateParentRun(uncertainCommit)
        try fixture.store.completeExecutionSnapshot(
            runID: "run-image-unknown",
            encodedSnapshot: try ExecutionSnapshotCodec.encode(snapshot)
        )
        try fixture.store.transitionRun(
            id: "run-image-unknown",
            expectedState: .preparing,
            to: .requestingModel
        )
        let unknownAttempt = AgentStepRecord(
            stepID: "image-input-run-image-unknown-\(fixture.image.versionID)",
            runID: "run-image-unknown",
            sequence: 0,
            attempt: 1,
            createdAt: Fixtures.epoch,
            purpose: .imageInput
        )
        try fixture.store.recordStep(unknownAttempt)
        #expect(try fixture.store.markImageInputStepStarted(
            runID: unknownAttempt.runID,
            identity: unknownAttempt.attemptIdentity
        ))
        try await RunRecovery(store: fixture.store, credentials: fixture.credentials)
            .recover(runID: "run-image-unknown")
        #expect(try fixture.store.run(id: "run-image-unknown")?.state == .failed)
        #expect(try fixture.store.steps(inRun: "run-image-unknown", purpose: .imageInput).count == 1)
        #expect(await fixture.provider.ledger.requests().map(\.modelID) == [ImageInputTestProvider.primaryModelID])
    }
}
