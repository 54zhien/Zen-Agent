import Foundation
import Testing

@testable import ZenAgent

@Suite("Execution snapshot")
struct ExecutionSnapshotTests {

    private static let snapshot = RunExecutionSnapshot(
        formatVersion: RunExecutionSnapshot.currentFormatVersion,
        providerID: .deepSeek,
        providerAdapterRevision: "deepseek-adapter-v1",
        prompt: .init(
            runtimeSafetyBaseline: "runtime-safety-v1",
            zenCore: "zen-core-v1",
            providerAdapterInstructions: "deepseek-instructions-v1"
        ),
        modelCapabilities: [.text, .streaming, .reasoning],
        exposedTools: [
            .init(
                toolID: "calculator",
                descriptorRevision: "calculator-v1",
                displayName: "Calculator",
                description: "Evaluate restricted arithmetic.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "expression": .object([
                            "type": .string("string")
                        ])
                    ])
                ])
            )
        ],
        maxProviderSteps: 8
    )

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    private func seedRun(in store: PersistenceStore) throws {
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )
    }

    @Test("snapshot codec round trips the complete execution boundary")
    func codecRoundTripsSnapshot() throws {
        let encoded = try ExecutionSnapshotCodec.encode(Self.snapshot)
        let decoded = try ExecutionSnapshotCodec.decode(encoded)

        #expect(decoded == Self.snapshot)
        #expect(decoded.formatVersion == RunExecutionSnapshot.currentFormatVersion)
    }

    @Test("explicit Child model target and request binding round trip in v5")
    func explicitDelegationTargetRoundTrips() throws {
        let target = DelegationModelTarget(
            providerInstanceID: ProviderInstanceID(rawValue: "child-provider-instance"),
            modelID: ModelID(rawValue: "child-model")
        )
        let binding = DelegationModelBindingSnapshot(
            providerID: .deepSeek,
            providerAdapterRevision: "deepseek-adapter-v1",
            modelCapabilities: [.text, .streaming],
            requestConfigSeed: RequestConfigSeed(
                providerInstanceID: target.providerInstanceID,
                modelID: target.modelID,
                providerConfigRevision: .initial,
                credentialBinding: CredentialBindingSnapshot(
                    reference: CredentialReference(id: "child-credential"),
                    generation: 3
                ),
                resolvedEndpoint: URL(string: "https://child.example/v1/chat/completions")!
            )
        )
        var snapshot = Self.snapshot
        snapshot.delegation = DelegationExecutionSnapshot(
            configuration: DelegationRuntimeConfiguration(
                enabled: true,
                explicitModelTarget: target,
                revision: 7
            ),
            explicitModelBinding: binding
        )

        let decoded = try ExecutionSnapshotCodec.decode(ExecutionSnapshotCodec.encode(snapshot))

        #expect(decoded.formatVersion == 5)
        #expect(decoded.delegation?.modelPolicy == .explicit)
        #expect(decoded.delegation?.explicitModelTarget == target)
        #expect(decoded.delegation?.explicitModelBinding == binding)
    }

    @Test("v4 delegation snapshots retain Follow Parent semantics")
    func v4DelegationSnapshotRemainsFollowParent() throws {
        let encoded = #"{"formatVersion":4,"providerID":"deepseek","providerAdapterRevision":"adapter-v1","prompt":{"runtimeSafetyBaseline":"runtime-v1","zenCore":"zen-v1","providerAdapterInstructions":""},"modelCapabilities":["text","streaming"],"exposedTools":[],"mcpServerDependencies":[],"maxProviderSteps":4,"delegation":{"revision":2,"enabled":true,"maxDepth":1,"maxConcurrentChildren":1,"modelPolicy":"followParent","environmentInheritance":"none"}}"#

        let decoded = try ExecutionSnapshotCodec.decode(encoded)

        #expect(decoded.formatVersion == 4)
        #expect(decoded.delegation?.modelPolicy == .followParent)
        #expect(decoded.delegation?.explicitModelTarget == nil)
        #expect(decoded.delegation?.explicitModelBinding == nil)
    }

    @Test("v2 snapshots remain readable without MCP server dependencies")
    func previousSnapshotVersionDefaultsMCPDependencies() throws {
        let encoded = #"{"formatVersion":2,"providerID":"deepseek","providerAdapterRevision":"adapter-v2","prompt":{"runtimeSafetyBaseline":"runtime-v1","zenCore":"zen-v1","providerAdapterInstructions":""},"modelCapabilities":["text","streaming"],"exposedTools":[],"maxProviderSteps":4}"#
        let decoded = try ExecutionSnapshotCodec.decode(encoded)
        #expect(decoded.formatVersion == 2)
        #expect(decoded.mcpServerDependencies.isEmpty)
    }

    @Test("snapshot format failures distinguish version states")
    func formatFailuresAreDistinct() throws {
        var failure: Error?
        do {
            _ = try ExecutionSnapshotCodec.decode(#"{"providerID":"deepseek"}"#)
        } catch {
            failure = error
        }
        #expect(failure as? RunExecutionSnapshot.FormatError == .unversioned)

        failure = nil
        do {
            _ = try ExecutionSnapshotCodec.decode(#"{"formatVersion":99}"#)
        } catch {
            failure = error
        }
        #expect(failure as? RunExecutionSnapshot.FormatError == .unsupportedVersion(99))

        failure = nil
        do {
            _ = try ExecutionSnapshotCodec.decode(#"{"formatVersion":\#(RunExecutionSnapshot.currentFormatVersion),"providerID":"deepseek"}"#)
        } catch {
            failure = error
        }
        #expect(
            failure as? RunExecutionSnapshot.FormatError
                == .malformedCurrentVersion(RunExecutionSnapshot.currentFormatVersion)
        )
    }

    @Test("preparing run stores one snapshot without rewriting its seed")
    func completesSnapshotOnce() throws {
        let store = try makeStore()
        try seedRun(in: store)

        let before = try store.run(id: "run-1")
        let encoded = try ExecutionSnapshotCodec.encode(Self.snapshot)
        try store.completeExecutionSnapshot(
            runID: "run-1",
            encodedSnapshot: encoded,
            at: Date(timeIntervalSince1970: 1_760_000_100)
        )

        let after = try store.run(id: "run-1")
        #expect(after?.executionSnapshot == encoded)
        #expect(after?.requestConfigSeed == before?.requestConfigSeed)

        var failure: Error?
        do {
            try store.completeExecutionSnapshot(
                runID: "run-1",
                encodedSnapshot: try ExecutionSnapshotCodec.encode(Self.snapshot),
                at: Date(timeIntervalSince1970: 1_760_000_101)
            )
        } catch {
            failure = error
        }
        guard let persistenceError = failure as? PersistenceError else {
            #expect(false, "expected a typed PersistenceError")
            return
        }
        if case .invalidTransition = persistenceError {
            // A completed snapshot is immutable and cannot be written a second time.
        } else {
            #expect(false, "expected invalidTransition, got \(persistenceError)")
        }
        #expect(try store.run(id: "run-1")?.executionSnapshot == encoded)
    }

    @Test("snapshot completion requires the run to remain preparing")
    func completionRequiresPreparingState() throws {
        let store = try makeStore()
        try seedRun(in: store)
        try store.transitionRun(
            id: "run-1",
            expectedState: .preparing,
            to: .requestingModel
        )

        var failure: Error?
        do {
            try store.completeExecutionSnapshot(
                runID: "run-1",
                encodedSnapshot: try ExecutionSnapshotCodec.encode(Self.snapshot)
            )
        } catch {
            failure = error
        }
        guard let persistenceError = failure as? PersistenceError else {
            #expect(false, "expected a typed PersistenceError")
            return
        }
        if case .invalidTransition = persistenceError {
            // A snapshot cannot be completed after preparing has ended.
        } else {
            #expect(false, "expected invalidTransition, got \(persistenceError)")
        }
        #expect(try store.run(id: "run-1")?.executionSnapshot == nil)
    }

    @Test("ordinary provider reconfiguration does not rewrite a frozen run snapshot")
    func providerReconfigurationLeavesFrozenRunUnchanged() throws {
        let store = try makeStore()
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi1"),
            providerID: .deepSeek,
            displayName: "Original",
            baseURL: URL(string: "https://original.example"),
            configRevision: .initial,
            credentialReference: CredentialReference(id: "cred-1")
        )
        try store.createProviderInstance(instance)
        try seedRun(in: store)

        let encoded = try ExecutionSnapshotCodec.encode(Self.snapshot)
        try store.completeExecutionSnapshot(runID: "run-1", encodedSnapshot: encoded)
        let before = try store.run(id: "run-1")
        let current = try store.providerInstance(id: instance.id)
        let expectedEditRevision = current?.editRevision ?? .initial

        _ = try store.reconfigureProviderInstance(
            id: instance.id,
            displayName: "Reconfigured",
            baseURL: URL(string: "https://changed.example"),
            expectedEditRevision: expectedEditRevision
        )

        let after = try store.run(id: "run-1")
        #expect(after?.requestConfigSeed == before?.requestConfigSeed)
        #expect(after?.executionSnapshot == before?.executionSnapshot)
    }
}
