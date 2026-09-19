import Foundation

/// Where the secret bytes live. The only thing the two implementations differ on.
///
/// Keeping the split at this seam is what makes "the fake and the real store follow the
/// same domain semantics" a structural fact rather than a promise: the generation rules,
/// the overwrite behaviour and the missing-credential handling are written once, above
/// this protocol, and both backends inherit them.
protocol SecretBackend: Sendable {
    func store(_ secret: SecretValue, for reference: CredentialReference) throws
    func load(_ reference: CredentialReference) throws -> SecretValue?
    func delete(_ reference: CredentialReference) throws
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
    /// The secret is temporarily unreadable — a locked device during a background
    /// launch, for instance. **Not the same as missing.**
    ///
    /// Kept distinct because collapsing it into `notFound` is how a background launch
    /// destroys a perfectly good token: the delete succeeds even when the read did not.
    case unavailable(CredentialReference, underlying: String)
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
    func metadata(for reference: CredentialReference) throws -> CredentialMetadata?
    func matchesBinding(_ reference: CredentialReference, generation: Int) throws -> Bool
}

/// The single implementation of the domain rules. Both backends go through it.
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
        try secrets.store(secret, for: reference)
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
        try secrets.store(secret, for: reference)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: existing.bindingGeneration,
            principalFingerprint: existing.principalFingerprint,
            status: .active,
            updatedAt: now
        ))
    }

    /// A different account behind the same reference. **Generation +1.**
    func rebind(
        _ secret: SecretValue,
        as reference: CredentialReference,
        principalFingerprint: String,
        at now: Date = Date()
    ) throws {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else {
            throw CredentialError.notFound(reference)
        }
        try secrets.store(secret, for: reference)
        try metadataRepository.saveMetadata(CredentialMetadata(
            reference: reference,
            bindingGeneration: existing.bindingGeneration + 1,
            principalFingerprint: principalFingerprint,
            status: .active,
            updatedAt: now
        ))
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
        try secrets.delete(reference)
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
    /// throws `unavailable` — the two are not interchangeable, and treating them as one
    /// is the documented way to lose a valid token.
    func resolve(_ reference: CredentialReference) throws -> SecretValue? {
        guard let existing = try metadataRepository.loadMetadata(for: reference) else { return nil }
        guard existing.status == .active else {
            throw CredentialError.authenticationRequired(reference)
        }
        do {
            return try secrets.load(reference)
        } catch SecretBackendError.unavailable(let reason) {
            // Translated here rather than left raw, so no caller sees an OSStatus and
            // has to decide whether "could not read" means "is not there". That
            // decision is the whole reason this error exists.
            throw CredentialError.unavailable(reference, underlying: reason)
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
