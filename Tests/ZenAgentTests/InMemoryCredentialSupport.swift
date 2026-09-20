import Foundation

@testable import ZenAgent

/// Test doubles for the credential boundary.
///
/// They implement only the two seams — where bytes live, and where metadata lives — and
/// nothing else. Every rule about generations, overwrites and missing credentials is
/// written once in `CredentialStore`, above those seams, so the fake and the Keychain
/// store cannot drift apart on semantics. If they could, testing against the fake would
/// prove nothing about the real one.
///
/// The metadata double is a plain dictionary rather than GRDB: a test that wants the
/// real metadata storage uses `PersistenceStore`, and one that wants determinism uses
/// this. Both are exercised.

/// Deterministic secret storage. No Keychain, no OSStatus, no device state.
///
/// Keys are versioned the same way the Keychain backend's are —
/// `"\(reference.id)#\(generation)"` — so the fake and the real store agree on the
/// one fact the binding-atomicity rules rest on: a secret stored for one generation
/// cannot be read under another.
final class InMemorySecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    /// When set, `load` throws `.unavailable` for these references — standing in for a
    /// locked device during a background launch. The condition the Keychain can produce
    /// and a naive implementation confuses with "not there".
    var unreadableReferences: Set<String> = []

    init() {}

    private func key(_ reference: CredentialReference, generation: Int) -> String {
        "\(reference.id)#\(generation)"
    }

    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[key(reference, generation: generation)] = secret.revealed
    }

    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        lock.lock(); defer { lock.unlock() }
        if unreadableReferences.contains(reference.id) {
            throw SecretBackendError.unavailable("simulated locked device")
        }
        return secrets[key(reference, generation: generation)].map(SecretValue.init)
    }

    func delete(_ reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: key(reference, generation: generation))
    }

    /// What is actually stored. Used by the test that checks the secret never reaches
    /// the database — it needs to know the exact bytes to search for.
    func storedSecret(for reference: CredentialReference, generation: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secrets[key(reference, generation: generation)]
    }
}

/// In-memory metadata storage with the same shape as the GRDB one.
final class InMemoryCredentialMetadataRepository: CredentialMetadataRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: CredentialMetadata] = [:]

    /// When set, the next `saveMetadata` throws. Consumed by the throw, so a later
    /// save succeeds. Simulates the persistence layer refusing a write after the
    /// secret backend has already committed — the interleaving a versioned key must
    /// survive.
    var failNextSave = false

    init() {}

    private func key(_ reference: CredentialReference) -> String {
        "\(reference.id)#\(reference.kind.rawValue)"
    }

    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        lock.lock(); defer { lock.unlock() }
        return store[key(reference)]
    }

    func saveMetadata(_ metadata: CredentialMetadata) throws {
        lock.lock(); defer { lock.unlock() }
        if failNextSave {
            failNextSave = false
            throw SimulatedMetadataWriteFailure()
        }
        store[key(metadata.reference)] = metadata
    }

    func deleteMetadata(for reference: CredentialReference) throws {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key(reference))
    }
}

/// What `failNextSave` throws. A concrete type rather than a generic `Error` so a
/// test can assert on it if it ever needs to.
struct SimulatedMetadataWriteFailure: Error, Equatable {}
