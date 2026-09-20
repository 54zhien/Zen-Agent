import Foundation

/// Where the secret bytes live. The only thing the two implementations differ on.
///
/// Keeping the split at this seam is what makes "the fake and the real store follow the
/// same domain semantics" a structural fact rather than a promise: the generation rules,
/// the overwrite behaviour and the missing-credential handling are written once, above
/// this protocol, and both backends inherit them.
protocol SecretBackend: Sendable {
    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws
    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue?
    func delete(_ reference: CredentialReference, generation: Int) throws
}

/// Non-secret metadata storage.
///
/// Declared here, implemented in `App/Persistence/` over GRDB — so this layer never
/// imports GRDB and the storage-engine boundary holds. The implementation can only ever
/// be handed `CredentialMetadata`, which is `Codable` precisely because everything in it
/// is safe to store.
protocol CredentialMetadataRepository: Sendable {
    func loadMetadata(for reference: CredentialReference) throws -> CredentialMetadata?
    func saveMetadata(_ metadata: CredentialMetadata) throws
    func deleteMetadata(for reference: CredentialReference) throws
}

enum CredentialError: Error, Equatable {
    /// Provisioning an id that already exists. The caller must choose `refresh` or
    /// `rebind`, because "same account, new token" and "different account" are
    /// decisions this layer cannot make on their behalf.
    case alreadyExists(CredentialReference)
    /// Refreshing, rebinding or logging out something never provisioned.
    case notFound(CredentialReference)
    /// The reference exists but was logged out or invalidated.
    case authenticationRequired(CredentialReference)
    /// The binding moved since the caller froze it: the metadata now records a
    /// different generation than the frozen one. (In a corrupted store it may
    /// even name a different reference — folded into the same case, because the
    /// answer is the same: what the caller froze no longer exists.)
    ///
    /// The reference string cannot tell — it is unchanged across a rebind and a
    /// logout — which is why this case carries both generations.
    case bindingMoved(
        CredentialReference,
        frozenGeneration: Int,
        currentGeneration: Int
    )
    /// The secret is temporarily unreadable — a locked device during a background
    /// launch, for instance. **Not the same as missing.**
    ///
    /// Kept distinct because collapsing it into `notFound` is how a background launch
    /// destroys a perfectly good token: the delete succeeds even when the read did not.
    case unavailable(CredentialReference, underlying: String)
    /// The store itself is damaged: the item exists but cannot be read or written,
    /// for a reason that is neither "missing" nor "temporarily locked".
    ///
    /// Distinct from `unavailable`, which promises "wait and try again" — damaged
    /// storage does not recover by waiting. Distinct from `notFound`, which would
    /// send the user to re-provision a credential that is still there.
    case failed(CredentialReference, underlying: String)
}

/// The credential boundary. Callers never touch `Security.framework`.
///
/// The four write operations and their generation rules are the point of the type:
///
/// | operation | secret | principal | generation |
/// |---|---|---|---|
/// | `provision` | set | set | starts at 1 |
/// | `refresh` | replaced | unchanged | **unchanged** |
/// | `rebind` | replaced | replaced | **+1** |
/// | `logout` | deleted | cleared | **+1** |
///
/// A refresh must not bump the generation, or every token rotation would invalidate
/// every paused run. A rebind must, or a suspended run frozen against the old account
/// would carry on against the new one — the reference string is identical in that case,
/// so only the generation separates them.
///
/// One protocol rather than a read/write split: the only callers so far are setup and
/// the tests, and inventing a narrower interface for a consumer that does not exist yet
/// would be guessing at where the seam belongs.
protocol CredentialStoring: Sendable {
    func provision(
        _ secret: SecretValue,
        as reference: CredentialReference,
        principalFingerprint: String?,
        at now: Date
    ) throws
    func refresh(_ secret: SecretValue, for reference: CredentialReference, at now: Date) throws
    func rebind(
        _ secret: SecretValue,
        as reference: CredentialReference,
        principalFingerprint: String,
        at now: Date
    ) throws
    func logout(_ reference: CredentialReference, at now: Date) throws

    func resolve(_ reference: CredentialReference) throws -> SecretValue?

    /// The secret, if the binding is still exactly the one the caller froze.
    ///
    /// One critical section: a **single** metadata read judges existence, status
    /// and generation together, and the secret is then loaded under the frozen
    /// generation. A rebind committed between a separate validation pass and
    /// this read is refused — the two-step shape where validation reads once,
    /// a rebind lands, and the second read hands the caller the new account's
    /// secret cannot be expressed through this interface.
    ///
    /// Status is judged before generation: a logged-out binding has also moved
    /// generations, and "the user logged out" is the diagnosis that tells them
    /// what to do. The generation check cannot.
    ///
    /// `nil` means there genuinely is no record for the frozen reference.
    func resolve(frozenReference: CredentialReference, generation: Int) throws -> SecretValue?

    func metadata(for reference: CredentialReference) throws -> CredentialMetadata?
    func matchesBinding(_ reference: CredentialReference, generation: Int) throws -> Bool
}

/// The single implementation of the domain rules. Both backends go through it.
///
/// Secrets are **versioned by generation**: the backend keys every stored secret by
/// `(reference, generation)`, so a secret written for generation N+1 lives under a
/// different key than the one a run frozen at N reads. "The old generation reads the
/// new account's secret" is therefore physically impossible — the old key is either
/// intact (old secret) or deleted (safe failure), and the new bytes are nowhere the
/// old generation looks. This is what makes the two-step rebind below safe: the
/// metadata write can fail at any point without ever misdirecting a secret.
struct CredentialStore: CredentialStoring {
    let secrets: any SecretBackend
    let metadataRepository: any CredentialMetadataRepository

    // MARK: - Provisioning

    /// First-time setup. Fails if the reference already exists.
    func provision(
        _ secret: SecretValue,
        as reference: CredentialReference,
        principalFingerprint: String? = nil,
        at now: Date = Date()
    ) throws {
        guard try metadataRepository.loadMetadata(for: reference) == nil else {
            throw CredentialError.alreadyExists(reference)
        }
        try secrets.store(secret, for: reference, generation: 1)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: 1,
            principalFingerprint: principalFingerprint,
            status: .active,
            updatedAt: now
        ))
    }

    /// A new token for the same binding. **Generation unchanged.**
    func refresh(_ secret: SecretValue, for reference: CredentialReference, at now: Date = Date()) throws {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else {
            throw CredentialError.notFound(reference)
        }
        try secrets.store(secret, for: reference, generation: existing.bindingGeneration)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: existing.bindingGeneration,
            principalFingerprint: existing.principalFingerprint,
            status: .active,
            updatedAt: now
        ))
    }

    /// A different account behind the same reference. **Generation +1.**
    ///
    /// The order is the mechanism. Store the new secret under the **next**
    /// generation's key first, commit the metadata, and only then delete the
    /// superseded key:
    ///
    /// 1. `store(gen+1)` puts the new bytes under a key nothing reads yet.
    /// 2. `saveMetadata(gen+1)` flips the world to the new generation.
    /// 3. `delete(gen)` removes the superseded key.
    ///
    /// If the metadata write fails, the old key is untouched and the old generation
    /// keeps reading its own secret — the new bytes sit under a key no metadata points
    /// at, and a later successful rebind reuses it. Deleting the old key only after
    /// the commit also means there is no state where the metadata has moved but the
    /// rebind is reported as failed; a crash between steps leaves at worst a stale
    /// old-generation key, which the next rebind's step 3 removes.
    func rebind(
        _ secret: SecretValue,
        as reference: CredentialReference,
        principalFingerprint: String,
        at now: Date = Date()
    ) throws {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else {
            throw CredentialError.notFound(reference)
        }
        let nextGeneration = existing.bindingGeneration + 1
        try secrets.store(secret, for: reference, generation: nextGeneration)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: nextGeneration,
            principalFingerprint: principalFingerprint,
            status: .active,
            updatedAt: now
        ))
        try secrets.delete(reference, generation: existing.bindingGeneration)
    }

    /// Forgets the secret. **Generation +1**, and the metadata stays.
    ///
    /// Kept rather than deleted so that "logged out" and "never provisioned" remain
    /// distinguishable, and so a run frozen against the old generation learns that the
    /// binding moved rather than that the record vanished.
    func logout(_ reference: CredentialReference, at now: Date = Date()) throws {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else {
            throw CredentialError.notFound(reference)
        }
        try secrets.delete(reference, generation: existing.bindingGeneration)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: existing.bindingGeneration + 1,
            principalFingerprint: nil,
            status: .authenticationRequired,
            updatedAt: now
        ))
    }

    // MARK: - Resolution

    /// The secret, if it is readable right now.
    ///
    /// `nil` means there genuinely is none. A credential that exists but cannot be read
    /// throws `unavailable` (temporarily locked) or `failed` (damaged storage) — the two
    /// are not interchangeable, and treating either as "missing" is the documented way
    /// to lose a valid token.
    func resolve(_ reference: CredentialReference) throws -> SecretValue? {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else { return nil }
        guard existing.status == .active else {
            throw CredentialError.authenticationRequired(reference)
        }
        do {
            return try secrets.load(reference, generation: existing.bindingGeneration)
        } catch let error as SecretBackendError {
            throw Self.credentialError(from: error, reference: reference)
        }
    }

    /// The secret, if the binding is still exactly the one the caller froze.
    ///
    /// Everything is decided from one metadata read: whether the record exists,
    /// whether it is active, and whether its generation is still the frozen one.
    /// Only then is the secret loaded — under the **frozen** generation, not
    /// whatever the metadata points at now, so the answer and the check can never
    /// come from two different moments. A rebind that commits after this read can
    /// at worst delete the frozen key (a safe, visible failure); it can never
    /// substitute a different account's bytes, because the new bytes live under a
    /// key this function will not look at.
    func resolve(frozenReference: CredentialReference, generation: Int) throws -> SecretValue? {
        guard let existing = try metadataRepository.loadMetadata(for: frozenReference) else {
            return nil
        }
        // Status before generation. A logged-out binding has moved generations
        // too, and reporting it as moved instead of logged out would send the
        // user looking for the wrong cause.
        guard existing.status == .active else {
            throw CredentialError.authenticationRequired(frozenReference)
        }
        guard existing.reference == frozenReference, existing.bindingGeneration == generation else {
            throw CredentialError.bindingMoved(
                frozenReference,
                frozenGeneration: generation,
                currentGeneration: existing.bindingGeneration
            )
        }
        do {
            return try secrets.load(frozenReference, generation: generation)
        } catch let error as SecretBackendError {
            throw Self.credentialError(from: error, reference: frozenReference)
        }
    }

    /// A backend failure, in the credential vocabulary. The one place
    /// `SecretBackendError` is translated, so no caller sees an OSStatus and has
    /// to decide whether "could not read" means "is not there" — that decision
    /// is the whole reason these two cases exist.
    private static func credentialError(
        from error: SecretBackendError,
        reference: CredentialReference
    ) -> CredentialError {
        switch error {
        case .unavailable(let reason):
            return .unavailable(reference, underlying: reason)
        case .failed(let reason):
            return .failed(reference, underlying: reason)
        }
    }

    func metadata(for reference: CredentialReference) throws -> CredentialMetadata? {
        try metadataRepository.loadMetadata(for: reference)
    }

    /// Whether a run frozen against `generation` may still use this credential.
    ///
    /// The check a recovering run needs. The reference id is identical before and after
    /// a rebind, so the string cannot answer it — only the generation can.
    func matchesBinding(_ reference: CredentialReference, generation: Int) throws -> Bool {
        try metadataRepository.loadMetadata(for: reference)?.bindingGeneration == generation
    }
}
