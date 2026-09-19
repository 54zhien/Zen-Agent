import Foundation
import Security

/// A failure from the secret backend, before it has been mapped to a domain error.
///
/// Separate from `CredentialError` because the backend knows about OSStatus values and
/// the domain does not. The mapping happens in one place, so no call site has to decide
/// what `-25308` means.
enum SecretBackendError: Error, Equatable {
    /// The item exists but cannot be read or written right now.
    ///
    /// Distinct from "not found" on purpose. See `KeychainSecretBackend.load`.
    case unavailable(String)
    /// Anything else the backend refused.
    case failed(String)
}

/// Keychain-backed secrets. **The only file in the app that imports `Security`.**
///
/// Enforced by a CI check, the same way GRDB is confined to `App/Persistence/`:
/// a boundary written in a document drifts, one expressed as a grep does not.
struct KeychainSecretBackend: SecretBackend {
    let service: String

    init(service: String = "com.zhien.zenagent.credentials") {
        self.service = service
    }

    // MARK: - SecretBackend

    func store(_ secret: SecretValue, for reference: CredentialReference) throws {
        let data = Data(secret.revealed.utf8)

        // Update first, so an existing item keeps its attributes.
        //
        // `SecItemUpdate` cannot change an item's accessibility — and the accessibility
        // is deliberately never in the query below, because including it in a *search*
        // is what produces the phantom "not found, then duplicate" mismatches.
        let updateStatus = SecItemUpdate(
            baseQuery(reference) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Self.map(updateStatus, reference: reference)
        }

        var addQuery = baseQuery(reference)
        addQuery[kSecValueData as String] = data
        // Set here and only here. See Docs/ADR/0003-keychain-accessibility.md.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.map(addStatus, reference: reference)
        }
    }

    /// The stored secret, or `nil` if there genuinely is none.
    ///
    /// **`errSecInteractionNotAllowed` is not `errSecItemNotFound`.** A locked device
    /// during a background launch returns the former, and reporting it as "no
    /// credential" is how a background launch ends up deleting a perfectly good token —
    /// the delete succeeds even when the read did not. So it is thrown, not swallowed
    /// into `nil`.
    func load(_ reference: CredentialReference) throws -> SecretValue? {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                throw SecretBackendError.failed("keychain item for \(reference.id) was not readable UTF-8")
            }
            return SecretValue(text)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.map(status, reference: reference)
        }
    }

    func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        // Deleting something already absent is not a failure; `logout` should be
        // idempotent from the caller's point of view.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.map(status, reference: reference)
        }
    }

    // MARK: - Internals

    /// The attributes that identify the item, and nothing else.
    ///
    /// `kSecAttrAccessible` is deliberately absent: it belongs in the add attributes,
    /// never in a search.
    private func baseQuery(_ reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id,
        ]
    }

    private static func map(_ status: OSStatus, reference: CredentialReference) -> SecretBackendError {
        if status == errSecInteractionNotAllowed {
            return .unavailable(
                "the keychain is not readable in this state for \(reference.id) (errSecInteractionNotAllowed)"
            )
        }
        return .failed("keychain status \(status) for \(reference.id)")
    }
}
