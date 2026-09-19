import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a secret reaches the Keychain and nowhere else.**
///
/// Three escapes are worth testing separately, because they fail for different reasons:
///
/// 1. **Storage** — the secret ending up in the database.
/// 2. **Serialisation** — the secret ending up in something `Codable`, which is how it
///    would get into the frozen request seed or an export.
/// 3. **Diagnostics** — the secret ending up in a log line or a crash report, which is
///    where it would outlive both the app and any chance of rotating it quietly.
///
/// The first two are prevented structurally rather than by care: `SecretValue` is not
/// `Codable`, so no arrangement of the types compiles. These tests check the property
/// holds in practice as well as in principle.
@Suite("Secret containment")
struct SecretContainmentTests {

    /// Distinctive enough that a byte scan cannot match it by accident.
    private static let marker = "sk-CONTAINMENT-PROBE-9f3a7c"

    private static let reference = CredentialReference(id: "probe-1")

    // MARK: - Storage

    @Test("no byte of the database contains the secret")
    func secretIsNotInTheDatabase() throws {
        let url = try Fixtures.scratchPath(name: "containment.sqlite")
        defer { Fixtures.cleanUp(url) }

        let database = try ZenDatabase.open(at: url.path())
        let store = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: PersistenceStore(database: database)
        )
        try store.provision(SecretValue(Self.marker), as: Self.reference, principalFingerprint: "acct-a")

        // Let the store close before reading the file, and read every file in the
        // directory — WAL means the newest bytes may not be in the .sqlite file itself,
        // and a check that reads only the main file would pass for the wrong reason.
        let directory = url.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        var scanned = 0
        for file in files {
            let bytes = try Data(contentsOf: file)
            scanned += bytes.count
            #expect(
                bytes.range(of: Data(Self.marker.utf8)) == nil,
                "the secret appears verbatim in \(file.lastPathComponent) — WAL included, because that is still the user's disk"
            )
        }
        #expect(scanned > 0, "the scan must actually have read something, or it proves nothing")

        // And what *is* stored is the non-secret half.
        let metadata = try store.metadata(for: Self.reference)
        #expect(metadata?.bindingGeneration == 1)
        #expect(metadata?.principalFingerprint == "acct-a")
    }

    // MARK: - Serialisation

    @Test("nothing Codable in the credential layer carries the secret")
    func secretIsNotEncodable() throws {
        let store = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try store.provision(SecretValue(Self.marker), as: Self.reference, principalFingerprint: "acct-a")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        guard let stored = try store.metadata(for: Self.reference) else {
            Issue.record("expected metadata after provisioning")
            return
        }
        let metadataJSON = String(decoding: try encoder.encode(stored), as: UTF8.self)
        #expect(
            !metadataJSON.contains(Self.marker),
            "the metadata is the part that goes to disk; it must be safe by construction"
        )

        // The frozen request seed is the other place a secret would be tempting to put,
        // and the one that would survive longest.
        let seed = RequestConfigSeed(
            providerInstanceID: ProviderInstanceID(rawValue: "pi1"),
            modelID: ModelID(rawValue: "deepseek-chat"),
            providerConfigRevision: ConfigRevision(rawValue: "r1"),
            credentialBinding: CredentialBindingSnapshot(reference: Self.reference, generation: 1)
        )
        let seedJSON = String(decoding: try encoder.encode(seed), as: UTF8.self)
        #expect(!seedJSON.contains(Self.marker))
        #expect(
            seedJSON.contains(Self.reference.id),
            "the seed names the credential instead — an identifier, not the material"
        )
        #expect(
            seedJSON.contains("generation"),
            "and which generation of it, so a rebind is visible to a recovering run"
        )
    }

    // MARK: - Diagnostics

    @Test("a secret does not print, describe, or reflect")
    func secretDoesNotLeakIntoDiagnostics() throws {
        let value = SecretValue(Self.marker)

        #expect(!String(describing: value).contains(Self.marker), "String(describing:) leaked the secret")
        #expect(!String(reflecting: value).contains(Self.marker), "String(reflecting:) leaked the secret")
        #expect(!value.description.contains(Self.marker))
        #expect(!value.debugDescription.contains(Self.marker))

        // The harder one: `String(describing:)` on a *containing* value reflects into its
        // fields. A nicer `description` on `SecretValue` alone would not have stopped
        // this — it takes `customMirror`.
        let containing = Container(secret: value, label: "not-a-secret")
        let dump = String(describing: containing)
        #expect(!dump.contains(Self.marker), "reflection into a containing value leaked the secret")
        #expect(dump.contains("not-a-secret"), "the sanity check: the dump must contain the non-secret field")

        // And what a diagnostic *should* be able to say about it.
        #expect(dump.contains("secret"), "a redacted marker is fine — the value is not")
    }
}

/// Stands in for any struct that happens to hold a secret. The point is that the
/// protection has to work for types this file does not control.
private struct Container {
    var secret: SecretValue
    var label: String
}
