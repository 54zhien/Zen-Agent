import Foundation
import Testing

@testable import ZenAgent

/// What the adapter sends, what it does with what comes back, and what it refuses to do.
///
/// Everything runs against `FakeHTTPTransport`, so no test needs a network or a key —
/// and, more usefully, every status code and every malformed body is reachable.
@Suite("DeepSeek provider")
struct DeepSeekProviderTests {

    // MARK: - Fixture

    struct Fixture {
        let provider: DeepSeekProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let seed: RequestConfigSeed
        let credentials: CredentialStore
        let secrets: InMemorySecretBackend
        let metadata: InMemoryCredentialMetadataRepository
        var reference: CredentialReference { CredentialReference(id: "cred-1") }
    }

    private func makeFixture(
        modelID: ModelID = ModelID(rawValue: "deepseek-flash"),
        model: String = "deepseek-flash"
    ) throws -> Fixture {
        let secrets = InMemorySecretBackend()
        let metadata = InMemoryCredentialMetadataRepository()
        let credentials = CredentialStore(secrets: secrets, metadataRepository: metadata)
        try credentials.provision(SecretValue("sk-test-9f3a7c"), as: CredentialReference(id: "cred-1"))

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com"),
            configRevision: .initial,
            credentialReference: CredentialReference(id: "cred-1")
        )

        let transport = FakeHTTPTransport()
        return Fixture(
            provider: DeepSeekProvider(transport: transport),
            transport: transport,
            instance: instance,
            seed: RequestConfigSeed(
                instance: instance,
                modelID: ModelID(rawValue: model),
                credentialBinding: CredentialBindingSnapshot(
                    reference: CredentialReference(id: "cred-1"),
                    generation: 1
                ),
                resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
            ),
            credentials: credentials,
            secrets: secrets,
            metadata: metadata
        )
    }

    private func request(_ model: String = "deepseek-flash") -> ProviderChatRequest {
        ProviderChatRequest(
            modelID: ModelID(rawValue: model),
            messages: [
                ProviderChatMessage(role: .system, content: "You are terse."),
                ProviderChatMessage(role: .user, content: "Hello"),
            ]
        )
    }

    private static let successJSON = """
    {
      "id": "chat-abc",
      "choices": [
        {
          "index": 0,
          "message": { "role": "assistant", "content": "Hi there." },
          "finish_reason": "stop"
        }
      ],
      "usage": { "prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16 }
    }
    """

    /// The mapping this test asserts, written out so a change to the adapter's mapping
    /// fails here rather than being absorbed by a restatement of the same expression.
    private static func expectedError(for status: Int) -> ProviderError? {
        switch status {
        case 400: return .invalidRequest("something")
        case 401: return .credentialRejected
        case 402: return .insufficientBalance
        case 422: return .invalidParameters("something")
        case 429: return .rateLimited(retryAfter: nil)
        case 500: return .serverError(status: 500)
        case 503: return .overloaded
        default: return nil
        }
    }

    // MARK: - What goes out

    @Test("the request goes to the chat completions endpoint over POST")
    func endpointAndMethod() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        let sent = try #require(f.transport.lastRequest)
        #expect(sent.method == .post)
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")
    }

    @Test("the credential is injected as a bearer token, and nowhere else")
    func authorizationHeader() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        let sent = try #require(f.transport.lastRequest)
        #expect(sent.headers["Authorization"] == "Bearer sk-test-9f3a7c")
        #expect(sent.headers["Content-Type"] == "application/json")
    }

    @Test("the body carries the model, the messages, and stream false")
    func requestBody() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        guard let body = f.transport.lastRequest?.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a JSON body on the request")
            return
        }

        #expect(json["model"] as? String == "deepseek-flash")
        #expect(json["stream"] as? Bool == false, "streaming is its own increment; this one must not be able to ask for it")
        guard let messages = json["messages"] as? [[String: String]] else {
            Issue.record("expected messages in the body")
            return
        }
        #expect(messages.count == 2)
        #expect(messages.first?["role"] == "system")
        #expect(messages.last?["content"] == "Hello")
    }

    @Test("no reasoning or thinking parameter is invented")
    func noInventedOptions() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        guard let body = f.transport.lastRequest?.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("expected a JSON body on the request")
            return
        }

        // The request sends exactly what Stage 1 uses. `reasoning_effort` exists and
        // DeepSeek would accept it, but sending it would mean picking a vocabulary before
        // there is a capability model to validate it against.
        #expect(Set(json.keys) == ["model", "messages", "stream"], "unexpected keys: \(json.keys.sorted())")
    }

    // MARK: - What comes back

    @Test("a normal response normalises to text, finish reason and usage")
    func normalisesSuccess() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        let response = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        #expect(response.id == "chat-abc")
        #expect(response.text == "Hi there.")
        #expect(response.finishReason == .stop)
        #expect(response.usage == ProviderTokenUsage(promptTokens: 12, completionTokens: 4, totalTokens: 16))
    }

    @Test("reasoning is passed through when present and left absent when not")
    func reasoningPresence() async throws {
        let withReasoning = """
        {"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"A","reasoning_content":"because"},"finish_reason":"stop"}]}
        """
        let f1 = try makeFixture()
        f1.transport.enqueue(status: 200, json: withReasoning)
        let reasoned = try await f1.provider.complete(request(), seed: f1.seed, instance: f1.instance, credentials: f1.credentials)
        #expect(reasoned.reasoning == "because")

        // Absent, not empty. A UI deciding whether to show a reasoning section needs the
        // difference, and `nil` versus `""` is the only way to carry it.
        let f2 = try makeFixture()
        f2.transport.enqueue(status: 200, json: Self.successJSON)
        let plain = try await f2.provider.complete(request(), seed: f2.seed, instance: f2.instance, credentials: f2.credentials)
        #expect(plain.reasoning == nil)
    }

    @Test("an unfamiliar finish reason is preserved rather than flattened to stop")
    func unknownFinishReason() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: """
        {"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"A"},"finish_reason":"something_new"}]}
        """)

        let response = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        // Reporting it as `.stop` is the shape of bug where a truncated answer looks
        // finished — which is exactly the case a user cannot detect for themselves.
        #expect(response.finishReason == .unknown("something_new"))
    }

    @Test("a response with no choices is malformed, not empty")
    func emptyChoicesIsMalformed() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: #"{"id":"c1","choices":[]}"#)

        await #expect(throws: ProviderError.malformedResponse("the response carried no choices")) {
            try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        }
    }

    @Test("a body that is not the expected shape is malformed")
    func malformedJSON() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: "not json at all")

        var failure: Error?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch {
            failure = error
        }
        guard case .malformedResponse = failure as? ProviderError else {
            Issue.record("expected .malformedResponse, got \(String(describing: failure))")
            return
        }
    }

    // MARK: - Status mapping

    @Test("each documented status maps to its own error", arguments: [
        (400, "invalid request"),
        (401, "authentication"),
        (402, "insufficient balance"),
        (422, "invalid parameters"),
        (429, "rate limited"),
        (500, "server error"),
        (503, "overloaded"),
    ])
    func statusMapping(status: Int, _ label: String) async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: status, json: #"{"error":{"message":"something"}}"#)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        #expect(
            failure == Self.expectedError(for: status),
            "\(label): expected \(String(describing: Self.expectedError(for: status))), got \(String(describing: failure))"
        )
    }

    @Test("a 429 keeps its Retry-After")
    func rateLimitRetryAfter() async throws {
        let f = try makeFixture()
        f.transport.enqueue(HTTPResponse(
            status: 429,
            headers: ["Retry-After": "30"],
            json: #"{"error":{"message":"slow down"}}"#
        ))

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        #expect(failure == .rateLimited(retryAfter: 30))
    }

    @Test("a provider message informs the text but does not become a type")
    func providerMessageIsOnlyDiagnostic() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 400, json: #"{"error":{"message":"model is required","type":"invalid_request_error","code":"400"}}"#)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        // The message is an associated value of a Zen error — a controlled diagnostic.
        // Nothing switches on DeepSeek's `type` or `code`, and no DeepSeek DTO escapes.
        #expect(failure == .invalidRequest("model is required"))
    }

    // MARK: - Transport failures

    @Test("a network failure surfaces as a transport failure")
    func networkFailure() async throws {
        let f = try makeFixture()
        f.transport.fail(with: .networkFailure("URLError code -1009"))

        await #expect(throws: ProviderError.transportFailure("URLError code -1009")) {
            try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        }
    }

    /// The provider's half of a chain whose transport half is a real socket.
    ///
    /// `URLSessionHTTPTransportTests` establishes that cancelling a caller while a
    /// refused response's body is draining surfaces `HTTPTransportError.cancelled` and
    /// not a status. This is the other end of that: the adapter turns it into
    /// `.cancelled` and into nothing else.
    ///
    /// The two halves are asserted in different suites because they are separately
    /// breakable, and each layer can be right on its own while the pair is wrong. A
    /// transport that reported the 401 it had already read would be behaving
    /// defensibly, and an adapter that mapped that 401 faithfully would be too — and the
    /// user who pressed Stop would be told their credential was rejected.
    @Test("cancellation surfaces as cancellation, not as a failure")
    func cancellation() async throws {
        let f = try makeFixture()
        f.transport.fail(with: .cancelled)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        // Distinct from a failure on purpose: a cancelled request is not a request that
        // went wrong, and reporting it as one would put an error in front of a user who
        // pressed Stop.
        //
        // Exact, so it also excludes `.credentialRejected` — which is the specific
        // inversion to guard against, because that case is not a message but the value
        // the availability judgement reads, and a cancellation is not evidence about a
        // credential.
        #expect(failure == .cancelled, "expected .cancelled, got \(String(describing: failure))")
    }

    // MARK: - No retry

    @Test("a retryable status still results in exactly one attempt", arguments: [429, 500, 503])
    func noHiddenRetry(status: Int) async throws {
        let f = try makeFixture()
        // Several responses queued, so a retry would find one and succeed — which is how
        // a hidden retry policy would pass unnoticed.
        f.transport.enqueue(status: status, json: #"{"error":{"message":"try later"}}"#)
        f.transport.enqueue(status: 200, json: Self.successJSON)

        _ = try? await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        #expect(
            f.transport.requestCount == 1,
            "expected one attempt, made \(f.transport.requestCount). A transport that retried a POST could send a second generation and present it as the first."
        )
    }

    // MARK: - Frozen configuration

    @Test("an edited instance is refused before anything is sent")
    func editedInstanceIsRefused() async throws {
        let f = try makeFixture()
        var edited = f.instance
        edited.configRevision = ConfigRevision(rawValue: "2")
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: edited, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected .configurationMismatch, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0, "a refused run must not reach the network at all")
    }

    @Test("a rebind since the freeze is refused")
    func rebindIsRefused() async throws {
        let f = try makeFixture()
        try f.credentials.rebind(SecretValue("sk-other"), as: f.reference, principalFingerprint: "acct-b")
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected .configurationMismatch after a rebind, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0)
    }

    @Test("a rebind landing between validation and resolution is refused, and nothing is sent")
    func rebindInterleavingIsRefused() async throws {
        // The window: validation has passed against generation 1, and the *next*
        // metadata read — the one that resolves the secret — finds a rebind
        // committed in between. The adapter must refuse the run, not carry the
        // new account's secret out.
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var reads = 0
        f.metadata.onLoadMetadata = {
            reads += 1
            guard reads == 2 else { return }
            // The second read is `resolve`'s: validation is done, the secret is
            // not yet fetched. Committing the rebind here is exactly the moment
            // a two-step read can be handed the new generation's secret.
            try? f.credentials.rebind(
                SecretValue("sk-other-account"), as: f.reference, principalFingerprint: "acct-b"
            )
        }

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record(
                """
                expected .configurationMismatch, got \(String(describing: failure)). A \
                rebind between validation and resolution must not let the request go out \
                under the new account's secret — the run was frozen against the old one.
                """
            )
            return
        }
        #expect(
            f.transport.requestCount == 0,
            "a run whose binding moved mid-dispatch must not reach the network at all"
        )
    }

    @Test("a model other than the frozen one is refused")
    func differentModelIsRefused() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(
                request("deepseek-v4-pro"),
                seed: f.seed,
                instance: f.instance,
                credentials: f.credentials
            )
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected .configurationMismatch for a model swap, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0)
    }

    // MARK: - Credential failures do not destroy anything

    @Test("a 401 does not delete, log out, or re-provision the credential")
    func rejectionDoesNotDestroyTheCredential() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 401, json: #"{"error":{"message":"Authentication Fails"}}"#)

        _ = try? await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        // The provider answered 401. That is evidence the credential is not accepted —
        // it is not an instruction to erase it. Destroying a user's credential on the
        // strength of one response is a data operation nobody asked for, and the response
        // might be a misconfiguration on the other side.
        #expect(
            try f.credentials.metadata(for: f.reference) != nil,
            "the credential record must survive a rejection"
        )
        #expect(
            try f.credentials.resolve(f.reference)?.revealed == "sk-test-9f3a7c",
            "the secret must still be readable — nothing about a 401 authorises deleting it"
        )
        #expect(try f.credentials.metadata(for: f.reference)?.bindingGeneration == 1)
    }

    @Test("a missing credential is reported as missing, not as rejected")
    func missingCredentialIsItsOwnError() async throws {
        let f = try makeFixture()
        var detached = f.instance
        detached.credentialReference = nil
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var failure: ProviderError?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: detached, credentials: f.credentials)
        } catch let error as ProviderError {
            failure = error
        }

        guard case .configurationMismatch = failure else {
            Issue.record("expected a refusal, got \(String(describing: failure))")
            return
        }
        #expect(f.transport.requestCount == 0)
    }

    // MARK: - Storage failures stay typed

    @Test("a backend failure surfaces as a provider error, not as a raw backend error")
    func storageFailureIsTyped() async throws {
        let f = try makeFixture()
        f.secrets.failedReferences = [f.reference.id]
        f.transport.enqueue(status: 200, json: Self.successJSON)

        var failure: Error?
        do {
            _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)
        } catch {
            failure = error
        }

        // The exact typed case — and one nothing retries, because retrying against
        // damaged storage changes nothing. A `SecretBackendError` escaping `complete`
        // would put a credential-layer type in front of the Runtime, the leak this
        // abstraction exists to prevent.
        #expect(
            failure as? ProviderError == .credentialStorageFailed(reason: "simulated damaged keychain item"),
            "expected .credentialStorageFailed, got \(String(describing: failure))"
        )
        #expect((failure as? ProviderError)?.retryDisposition == .doNotRetry)
        #expect(!(failure is SecretBackendError), "the backend error must not escape the adapter")
        #expect(f.transport.requestCount == 0, "damaged storage must not send anything")
    }

    // MARK: - Secrets

    @Test("the secret appears in no description, dump, or error")
    func secretDoesNotLeak() async throws {
        let f = try makeFixture()
        f.transport.enqueue(status: 200, json: Self.successJSON)
        _ = try await f.provider.complete(request(), seed: f.seed, instance: f.instance, credentials: f.credentials)

        let sent = try #require(f.transport.lastRequest)
        let marker = "sk-test-9f3a7c"

        // The request carries it — that is what the header is for. Everything that could
        // print the request must not.
        #expect(sent.headers["Authorization"]?.contains(marker) == true, "the header must actually carry it")
        #expect(!String(describing: sent).contains(marker), "String(describing:) on the request leaked it")
        #expect(!String(reflecting: sent).contains(marker), "String(reflecting:) leaked it")
        #expect(!String(describing: (sent, f.instance, f.seed)).contains(marker), "reflection into a containing value leaked it")
        #expect(String(describing: sent).contains("<redacted>"), "the redaction marker should be visible")

        // And an error raised from a rejected credential carries none of it.
        let g = try makeFixture()
        g.transport.enqueue(status: 401, json: #"{"error":{"message":"Authentication Fails"}}"#)
        var failure: Error?
        do {
            _ = try await g.provider.complete(request(), seed: g.seed, instance: g.instance, credentials: g.credentials)
        } catch {
            failure = error
        }
        #expect(!String(describing: failure).contains(marker), "an error description leaked the secret")
    }

    // MARK: - The full path

    @Test("keychain to credential store to provider to request, intercepted before the network")
    func endToEndThroughFakeTransport() async throws {
        // The real Keychain, the real credential store, the real adapter, the real
        // request builder — and a fake transport standing in for the wire. What this
        // covers that the other tests do not is the wiring between them.
        let secrets = KeychainSecretBackend(service: "zen-e2e-\(UUID().uuidString)")
        let metadata = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(secrets: secrets, metadataRepository: metadata)

        let reference = CredentialReference(id: "e2e-cred")
        try credentials.provision(SecretValue("sk-e2e-secret"), as: reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "e2e-instance"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: DeepSeekProvider.defaultBaseURL,
            configRevision: .initial,
            credentialReference: reference
        )
        try metadata.createProviderInstance(instance)

        let transport = FakeHTTPTransport()
        transport.enqueue(status: 200, json: Self.successJSON)
        let provider = DeepSeekProvider(transport: transport)

        let seed = RequestConfigSeed(
            instance: instance,
            modelID: ModelID(rawValue: "deepseek-flash"),
            credentialBinding: CredentialBindingSnapshot(reference: reference, generation: 1),
            resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
        )
        let response = try await provider.complete(request(), seed: seed, instance: instance, credentials: credentials)

        #expect(response.text == "Hi there.")
        let sent = try #require(transport.lastRequest)
        #expect(sent.headers["Authorization"] == "Bearer sk-e2e-secret")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")

        // Cleanup. The secret was provisioned at generation 1 and never rebound, so
        // the generation-versioned key is "e2e-cred#1".
        try? secrets.delete(reference, generation: 1)
    }
}
