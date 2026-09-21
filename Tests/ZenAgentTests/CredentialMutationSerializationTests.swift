import Foundation
import Testing

@testable import ZenAgent

struct CredentialConcurrencyBackendPair: Sendable {
    let secrets: any SecretBackend
    let metadata: any CredentialMetadataRepository
}

enum CredentialConcurrencyBackend: String, CaseIterable, Sendable {
    case inMemory
    case keychainAndGRDB

    func makePair() throws -> CredentialConcurrencyBackendPair {
        switch self {
        case .inMemory:
            return CredentialConcurrencyBackendPair(
                secrets: InMemorySecretBackend(),
                metadata: InMemoryCredentialMetadataRepository()
            )

        case .keychainAndGRDB:
            return CredentialConcurrencyBackendPair(
                secrets: KeychainSecretBackend(
                    service: "zen-z01-\(UUID().uuidString)"
                ),
                metadata: PersistenceStore(
                    database: try ZenDatabase.inMemory()
                )
            )
        }
    }
}

private final class HookedSecretBackend:
    SecretBackend,
    @unchecked Sendable
{
    typealias StoreHook =
        @Sendable (SecretValue, CredentialReference, Int) -> Void

    typealias LoadHook =
        @Sendable (CredentialReference, Int, SecretValue?) -> Void

    typealias DeleteHook =
        @Sendable (CredentialReference, Int) -> Void

    private let base: any SecretBackend
    private let hookLock = NSLock()

    private var afterStoreHook: StoreHook?
    private var afterLoadHook: LoadHook?
    private var afterDeleteHook: DeleteHook?

    init(base: any SecretBackend) {
        self.base = base
    }

    func setAfterStore(_ hook: StoreHook?) {
        hookLock.lock()
        afterStoreHook = hook
        hookLock.unlock()
    }

    func setAfterLoad(_ hook: LoadHook?) {
        hookLock.lock()
        afterLoadHook = hook
        hookLock.unlock()
    }

    func setAfterDelete(_ hook: DeleteHook?) {
        hookLock.lock()
        afterDeleteHook = hook
        hookLock.unlock()
    }

    func store(
        _ secret: SecretValue,
        for reference: CredentialReference,
        generation: Int
    ) throws {
        try base.store(
            secret,
            for: reference,
            generation: generation
        )

        storeHookSnapshot()?(
            secret,
            reference,
            generation
        )
    }

    func load(
        _ reference: CredentialReference,
        generation: Int
    ) throws -> SecretValue? {
        let value = try base.load(
            reference,
            generation: generation
        )

        loadHookSnapshot()?(
            reference,
            generation,
            value
        )

        return value
    }

    func delete(
        _ reference: CredentialReference,
        generation: Int
    ) throws {
        try base.delete(
            reference,
            generation: generation
        )

        deleteHookSnapshot()?(
            reference,
            generation
        )
    }

    private func storeHookSnapshot() -> StoreHook? {
        hookLock.lock()
        defer { hookLock.unlock() }
        return afterStoreHook
    }

    private func loadHookSnapshot() -> LoadHook? {
        hookLock.lock()
        defer { hookLock.unlock() }
        return afterLoadHook
    }

    private func deleteHookSnapshot() -> DeleteHook? {
        hookLock.lock()
        defer { hookLock.unlock() }
        return afterDeleteHook
    }
}

private final class HookedCredentialMetadataRepository:
    CredentialMetadataRepository,
    @unchecked Sendable
{
    typealias SaveHook =
        @Sendable (CredentialMetadata) -> Void

    private let base: any CredentialMetadataRepository
    private let hookLock = NSLock()

    private var afterSaveHook: SaveHook?

    init(base: any CredentialMetadataRepository) {
        self.base = base
    }

    func setAfterSave(_ hook: SaveHook?) {
        hookLock.lock()
        afterSaveHook = hook
        hookLock.unlock()
    }

    func loadMetadata(
        for reference: CredentialReference
    ) throws -> CredentialMetadata? {
        try base.loadMetadata(for: reference)
    }

    func saveMetadata(
        _ metadata: CredentialMetadata
    ) throws {
        try base.saveMetadata(metadata)
        saveHookSnapshot()?(metadata)
    }

    func deleteMetadata(
        for reference: CredentialReference
    ) throws {
        try base.deleteMetadata(for: reference)
    }

    private func saveHookSnapshot() -> SaveHook? {
        hookLock.lock()
        defer { hookLock.unlock() }
        return afterSaveHook
    }
}

private final class CredentialMutationBarrier:
    @unchecked Sendable
{
    private let firstOperationReached =
        DispatchSemaphore(value: 0)

    private let competitorStarted =
        DispatchSemaphore(value: 0)

    private let competitorCommitted =
        DispatchSemaphore(value: 0)

    private let stateLock = NSLock()

    private var overlap = false
    private var harnessFailed = false

    func holdFirstOperation() {
        firstOperationReached.signal()

        guard
            competitorStarted.wait(
                timeout: .now() + .seconds(5)
            ) == .success
        else {
            stateLock.lock()
            harnessFailed = true
            stateLock.unlock()
            return
        }

        let didOverlap =
            competitorCommitted.wait(
                timeout: .now() + .seconds(2)
            ) == .success

        stateLock.lock()
        overlap = didOverlap
        stateLock.unlock()
    }

    func waitForFirstOperation() -> Bool {
        firstOperationReached.wait(
            timeout: .now() + .seconds(5)
        ) == .success
    }

    func competitorDidStart() {
        competitorStarted.signal()
    }

    func competitorDidCommit() {
        competitorCommitted.signal()
    }

    func markHarnessFailure() {
        stateLock.lock()
        harnessFailed = true
        stateLock.unlock()
    }

    var observedOverlap: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return overlap
    }

    var harnessFailure: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return harnessFailed
    }
}

private final class CredentialMutationFailures:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [any Error] = []

    func capture(
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            lock.lock()
            storage.append(error)
            lock.unlock()
        }
    }

    var snapshot: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ResolvedSecretCapture:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: String?

    func record(
        _ secret: SecretValue?
    ) {
        lock.lock()
        storage = secret?.revealed
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct CredentialConcurrencyHarness:
    Sendable
{
    let reference: CredentialReference

    let secrets: HookedSecretBackend
    let metadata: HookedCredentialMetadataRepository

    let firstStore: CredentialStore
    let secondStore: CredentialStore

    init(
        backend: CredentialConcurrencyBackend,
        testName: String
    ) throws {
        reference = CredentialReference(
            id: "z01-\(testName)-\(backend.rawValue)-\(UUID().uuidString)"
        )

        let pair = try backend.makePair()

        let secrets = HookedSecretBackend(
            base: pair.secrets
        )

        let metadata =
            HookedCredentialMetadataRepository(
                base: pair.metadata
            )

        self.secrets = secrets
        self.metadata = metadata

        firstStore = CredentialStore(
            secrets: secrets,
            metadataRepository: metadata
        )

        secondStore = CredentialStore(
            secrets: secrets,
            metadataRepository: metadata
        )
    }
}

@Suite("Credential mutation serialization")
struct CredentialMutationSerializationTests {

    private func exerciseInterleaving(
        label: String,
        barrier: CredentialMutationBarrier,
        first: @escaping @Sendable () throws -> Void,
        second: @escaping @Sendable () throws -> Void
    ) -> CredentialMutationFailures {
        let failures = CredentialMutationFailures()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue(
            label: "\(label).first"
        ).async {
            defer { group.leave() }
            failures.capture(first)
        }

        guard barrier.waitForFirstOperation() else {
            barrier.markHarnessFailure()

            Issue.record(
                "the first operation never reached its controlled barrier"
            )

            _ = group.wait(
                timeout: .now() + .seconds(10)
            )

            return failures
        }

        group.enter()
        DispatchQueue(
            label: "\(label).second"
        ).async {
            defer { group.leave() }

            // This distinguishes a competing queue closure that never started
            // from one that did start. It does NOT prove that the second
            // CredentialStore operation has already begun or has already
            // attempted to acquire the credential coordinator lock.
            barrier.competitorDidStart()

            failures.capture(second)
        }

        guard
            group.wait(
                timeout: .now() + .seconds(10)
            ) == .success
        else {
            barrier.markHarnessFailure()

            Issue.record(
                "credential operations did not complete after the controlled barrier"
            )

            return failures
        }

        return failures
    }

    @Test(
        "two stores cannot concurrently provision the same reference",
        arguments: CredentialConcurrencyBackend.allCases
    )
    func concurrentProvision(
        backend: CredentialConcurrencyBackend
    ) throws {
        let harness =
            try CredentialConcurrencyHarness(
                backend: backend,
                testName: "provision"
            )

        let reference = harness.reference
        let secrets = harness.secrets
        let barrier = CredentialMutationBarrier()

        secrets.setAfterStore {
            secret,
            candidate,
            generation in

            guard
                candidate == reference,
                generation == 1,
                secret.revealed == "sk-a"
            else {
                return
            }

            secrets.setAfterStore(nil)
            barrier.holdFirstOperation()
        }

        harness.metadata.setAfterSave {
            metadata in

            if
                metadata.reference == reference,
                metadata.principalFingerprint == "acct-b"
            {
                barrier.competitorDidCommit()
            }
        }

        let firstStore = harness.firstStore
        let secondStore = harness.secondStore

        let failures = exerciseInterleaving(
            label:
                "credential.provision.\(backend.rawValue)",
            barrier: barrier,
            first: {
                try firstStore.provision(
                    SecretValue("sk-a"),
                    as: reference,
                    principalFingerprint: "acct-a"
                )
            },
            second: {
                try secondStore.provision(
                    SecretValue("sk-b"),
                    as: reference,
                    principalFingerprint: "acct-b"
                )
            }
        )

        let captured = failures.snapshot

        #expect(!barrier.harnessFailure)
        #expect(!barrier.observedOverlap)

        #expect(captured.count == 1)

        if let failure = captured.first {
            #expect(
                failure as? CredentialError
                    == .alreadyExists(reference)
            )
        }

        #expect(
            try firstStore
                .metadata(for: reference)?
                .bindingGeneration == 1
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .principalFingerprint == "acct-a"
        )

        #expect(
            try firstStore
                .resolve(reference)?
                .revealed == "sk-a"
        )
    }

    @Test(
        "two rebinds cannot reuse one generation",
        arguments: CredentialConcurrencyBackend.allCases
    )
    func concurrentRebinds(
        backend: CredentialConcurrencyBackend
    ) throws {
        let harness =
            try CredentialConcurrencyHarness(
                backend: backend,
                testName: "double-rebind"
            )

        let reference = harness.reference
        let secrets = harness.secrets
        let barrier = CredentialMutationBarrier()

        try harness.firstStore.provision(
            SecretValue("sk-original"),
            as: reference,
            principalFingerprint: "acct-a"
        )

        secrets.setAfterStore {
            secret,
            candidate,
            generation in

            guard
                candidate == reference,
                generation == 2,
                secret.revealed == "sk-b"
            else {
                return
            }

            secrets.setAfterStore(nil)
            barrier.holdFirstOperation()
        }

        harness.metadata.setAfterSave {
            metadata in

            if
                metadata.reference == reference,
                metadata.principalFingerprint == "acct-c"
            {
                barrier.competitorDidCommit()
            }
        }

        let firstStore = harness.firstStore
        let secondStore = harness.secondStore

        let failures = exerciseInterleaving(
            label:
                "credential.double-rebind.\(backend.rawValue)",
            barrier: barrier,
            first: {
                try firstStore.rebind(
                    SecretValue("sk-b"),
                    as: reference,
                    principalFingerprint: "acct-b"
                )
            },
            second: {
                try secondStore.rebind(
                    SecretValue("sk-c"),
                    as: reference,
                    principalFingerprint: "acct-c"
                )
            }
        )

        #expect(!barrier.harnessFailure)
        #expect(!barrier.observedOverlap)
        #expect(failures.snapshot.isEmpty)

        #expect(
            try firstStore
                .metadata(for: reference)?
                .bindingGeneration == 3
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .principalFingerprint == "acct-c"
        )

        #expect(
            try firstStore
                .resolve(reference)?
                .revealed == "sk-c"
        )
    }

    @Test(
        "refresh cannot roll metadata back across a rebind",
        arguments: CredentialConcurrencyBackend.allCases
    )
    func refreshVersusRebind(
        backend: CredentialConcurrencyBackend
    ) throws {
        let harness =
            try CredentialConcurrencyHarness(
                backend: backend,
                testName: "refresh-rebind"
            )

        let reference = harness.reference
        let secrets = harness.secrets
        let barrier = CredentialMutationBarrier()

        try harness.firstStore.provision(
            SecretValue("sk-original"),
            as: reference,
            principalFingerprint: "acct-a"
        )

        secrets.setAfterStore {
            secret,
            candidate,
            generation in

            guard
                candidate == reference,
                generation == 1,
                secret.revealed == "sk-refreshed"
            else {
                return
            }

            secrets.setAfterStore(nil)
            barrier.holdFirstOperation()
        }

        harness.metadata.setAfterSave {
            metadata in

            if
                metadata.reference == reference,
                metadata.principalFingerprint == "acct-b"
            {
                barrier.competitorDidCommit()
            }
        }

        let firstStore = harness.firstStore
        let secondStore = harness.secondStore

        let failures = exerciseInterleaving(
            label:
                "credential.refresh-rebind.\(backend.rawValue)",
            barrier: barrier,
            first: {
                try firstStore.refresh(
                    SecretValue("sk-refreshed"),
                    for: reference
                )
            },
            second: {
                try secondStore.rebind(
                    SecretValue("sk-b"),
                    as: reference,
                    principalFingerprint: "acct-b"
                )
            }
        )

        #expect(!barrier.harnessFailure)
        #expect(!barrier.observedOverlap)
        #expect(failures.snapshot.isEmpty)

        #expect(
            try firstStore
                .metadata(for: reference)?
                .bindingGeneration == 2
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .principalFingerprint == "acct-b"
        )

        #expect(
            try firstStore
                .resolve(reference)?
                .revealed == "sk-b"
        )
    }

    @Test(
        "logout and rebind cannot reuse one generation",
        arguments: CredentialConcurrencyBackend.allCases
    )
    func logoutVersusRebind(
        backend: CredentialConcurrencyBackend
    ) throws {
        let harness =
            try CredentialConcurrencyHarness(
                backend: backend,
                testName: "logout-rebind"
            )

        let reference = harness.reference
        let secrets = harness.secrets
        let barrier = CredentialMutationBarrier()

        try harness.firstStore.provision(
            SecretValue("sk-original"),
            as: reference,
            principalFingerprint: "acct-a"
        )

        secrets.setAfterDelete {
            candidate,
            generation in

            guard
                candidate == reference,
                generation == 1
            else {
                return
            }

            secrets.setAfterDelete(nil)
            barrier.holdFirstOperation()
        }

        harness.metadata.setAfterSave {
            metadata in

            if
                metadata.reference == reference,
                metadata.principalFingerprint == "acct-b"
            {
                barrier.competitorDidCommit()
            }
        }

        let firstStore = harness.firstStore
        let secondStore = harness.secondStore

        let failures = exerciseInterleaving(
            label:
                "credential.logout-rebind.\(backend.rawValue)",
            barrier: barrier,
            first: {
                try firstStore.logout(reference)
            },
            second: {
                try secondStore.rebind(
                    SecretValue("sk-b"),
                    as: reference,
                    principalFingerprint: "acct-b"
                )
            }
        )

        #expect(!barrier.harnessFailure)
        #expect(!barrier.observedOverlap)
        #expect(failures.snapshot.isEmpty)

        #expect(
            try firstStore
                .metadata(for: reference)?
                .bindingGeneration == 3
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .status == .active
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .principalFingerprint == "acct-b"
        )

        #expect(
            try firstStore
                .resolve(reference)?
                .revealed == "sk-b"
        )
    }

    @Test(
        "a frozen resolve and a rebind share the same critical section",
        arguments: CredentialConcurrencyBackend.allCases
    )
    func frozenResolveVersusRebind(
        backend: CredentialConcurrencyBackend
    ) throws {
        let harness =
            try CredentialConcurrencyHarness(
                backend: backend,
                testName: "resolve-rebind"
            )

        let reference = harness.reference
        let secrets = harness.secrets

        let barrier = CredentialMutationBarrier()
        let resolved = ResolvedSecretCapture()

        try harness.firstStore.provision(
            SecretValue("sk-original"),
            as: reference,
            principalFingerprint: "acct-a"
        )

        secrets.setAfterLoad {
            candidate,
            generation,
            value in

            guard
                candidate == reference,
                generation == 1,
                value?.revealed == "sk-original"
            else {
                return
            }

            secrets.setAfterLoad(nil)
            barrier.holdFirstOperation()
        }

        harness.metadata.setAfterSave {
            metadata in

            if
                metadata.reference == reference,
                metadata.principalFingerprint == "acct-b"
            {
                barrier.competitorDidCommit()
            }
        }

        let firstStore = harness.firstStore
        let secondStore = harness.secondStore

        let failures = exerciseInterleaving(
            label:
                "credential.resolve-rebind.\(backend.rawValue)",
            barrier: barrier,
            first: {
                resolved.record(
                    try firstStore.resolve(
                        frozenReference: reference,
                        generation: 1
                    )
                )
            },
            second: {
                try secondStore.rebind(
                    SecretValue("sk-b"),
                    as: reference,
                    principalFingerprint: "acct-b"
                )
            }
        )

        #expect(!barrier.harnessFailure)
        #expect(!barrier.observedOverlap)
        #expect(failures.snapshot.isEmpty)

        #expect(
            resolved.value == "sk-original"
        )

        #expect(
            try firstStore
                .metadata(for: reference)?
                .bindingGeneration == 2
        )

        #expect(
            try firstStore
                .resolve(reference)?
                .revealed == "sk-b"
        )
    }
}
