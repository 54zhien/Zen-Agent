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
            _ = try ExecutionSnapshotCodec.decode(#"{"formatVersion":1,"providerID":"deepseek"}"#)
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
