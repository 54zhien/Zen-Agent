import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **a request goes to the endpoint of the instance the run was frozen
/// against, and the credential goes with it and nowhere else.**
///
/// This exists because the adapter used to carry an endpoint of its own alongside the
/// instance's — two sources of truth for one URL, and only one of them visible to the
/// user in Settings. A second endpoint that streaming could take while non-streaming took
/// the first is precisely how a credential ends up somewhere the run was never frozen
/// against, and the header is not the part that notices.
@Suite("Endpoint resolution")
struct EndpointResolutionTests {

    private static let custom = URL(string: "https://proxy.example.com")!
    private static let reference = CredentialReference(id: "cred-1")
    private static let chatCompletions = "chat/completions"

    static let successJSON = #"{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#

    struct Fixture {
        let provider: DeepSeekProvider
        let transport: FakeHTTPTransport
        let instance: ProviderInstance
        let seed: RequestConfigSeed
        let credentials: CredentialStore

        /// Runs both paths, so a test can compare what each of them actually sent.
        func runBothPaths() async {
            transport.enqueue(status: 200, json: EndpointResolutionTests.successJSON)
            _ = try? await provider.complete(
                request, seed: seed, instance: instance, credentials: credentials
            )

            transport.enqueueStream(["data: [DONE]\n\n"])
            _ = try? await provider.stream(
                request, seed: seed, instance: instance, credentials: credentials
            )
        }

        var request: ProviderChatRequest {
            ProviderChatRequest(
                modelID: ModelID(rawValue: "deepseek-flash"),
                messages: [ProviderChatMessage(role: .user, content: "Hello")]
            )
        }
    }

    private func makeFixture(instanceBaseURL: URL?) throws -> Fixture {
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(SecretValue("sk-endpoint-probe"), as: Self.reference)

        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "pi-1"),
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: instanceBaseURL,
            configRevision: .initial,
            credentialReference: Self.reference
        )
        let transport = FakeHTTPTransport()
        return Fixture(
            provider: DeepSeekProvider(transport: transport),
            transport: transport,
            instance: instance,
            seed: RequestConfigSeed(
                instance: instance,
                modelID: ModelID(rawValue: "deepseek-flash"),
                credentialBinding: CredentialBindingSnapshot(reference: Self.reference, generation: 1),
                resolvedEndpoint: DeepSeekProvider.resolvedEndpoint(for: instance)
            ),
            credentials: credentials
        )
    }

    @Test("both paths send to the instance's endpoint")
    func bothPathsUseTheInstanceEndpoint() async throws {
        let f = try makeFixture(instanceBaseURL: Self.custom)

        f.transport.enqueue(status: 200, json: Self.successJSON)
        _ = try? await f.provider.complete(f.request, seed: f.seed, instance: f.instance, credentials: f.credentials)
        let afterComplete = try #require(f.transport.lastRequest)

        f.transport.enqueueStream(["data: [DONE]\n\n"])
        _ = try? await f.provider.stream(f.request, seed: f.seed, instance: f.instance, credentials: f.credentials)
        let afterStream = try #require(f.transport.lastRequest)

        let expected = "https://proxy.example.com/\(Self.chatCompletions)"
        #expect(afterComplete.url.absoluteString == expected)
        #expect(
            afterStream.url.absoluteString == expected,
            "the two paths must not resolve the endpoint differently — that is the bug this suite exists for"
        )
        // And the URL that went out is the one the seed names, not one rebuilt from the
        // instance. With the check below in place these cannot differ, which is the
        // point — this pins that the seed is what the request is built from.
        #expect(afterComplete.url == f.seed.endpoint)
        #expect(afterStream.url == f.seed.endpoint)
    }

    /// **The drift case.** An instance with no endpoint resolves to a compile-time
    /// default, and a default can move between builds. A run frozen before such a change
    /// must be refused, not quietly sent somewhere it was never pointed at — carrying its
    /// credential with it, with every other check in the validation still passing.
    ///
    /// This is what the endpoint being *in* the seed buys. Without it the seed records
    /// the instance and the revision, both of which are unchanged here, and the run
    /// resumes against whatever the constant says now.
    @Test("a run frozen against one endpoint is refused when the instance resolves elsewhere")
    func frozenEndpointDriftIsRefused() async throws {
        let f = try makeFixture(instanceBaseURL: nil)

        // The instance resolves to the provider default. The seed says somewhere else,
        // which is exactly what a run frozen before the default changed looks like.
        let drifted = RequestConfigSeed(
            instance: f.instance,
            modelID: ModelID(rawValue: "deepseek-flash"),
            credentialBinding: CredentialBindingSnapshot(reference: Self.reference, generation: 1),
            resolvedEndpoint: URL(string: "https://frozen.example/v1/chat/completions")!
        )
        // Nothing about the instance moved, so the checks that existed before this one
        // all still pass. That is what makes the case worth a test of its own.
        #expect(f.instance.configRevision == drifted.providerConfigRevision)
        #expect(f.instance.matches(drifted))

        f.transport.enqueue(status: 200, json: Self.successJSON)
        f.transport.enqueueStream(["data: [DONE]\n\n"])

        let fromComplete = await failure {
            _ = try await f.provider.complete(f.request, seed: drifted, instance: f.instance, credentials: f.credentials)
        }
        guard case .configurationMismatch = fromComplete else {
            Issue.record("expected the non-streaming path to refuse, got \(String(describing: fromComplete))")
            return
        }

        let fromStream = await failure {
            _ = try await f.provider.stream(f.request, seed: drifted, instance: f.instance, credentials: f.credentials)
        }
        guard case .configurationMismatch = fromStream else {
            Issue.record("expected the streaming path to refuse, got \(String(describing: fromStream))")
            return
        }

        #expect(
            f.transport.requestCount == 0,
            "a refused run must not reach the network — not even to find out"
        )
    }

    /// Runs a call that is expected to fail, and reports what it threw.
    private func failure(_ body: () async throws -> Void) async -> ProviderError? {
        do {
            try await body()
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            return nil
        }
    }

    @Test("an instance with no endpoint falls back to the provider default, on both paths")
    func absentEndpointFallsBack() async throws {
        let f = try makeFixture(instanceBaseURL: nil)
        let expected = DeepSeekProvider.defaultBaseURL.appending(path: Self.chatCompletions)

        f.transport.enqueue(status: 200, json: Self.successJSON)
        _ = try? await f.provider.complete(f.request, seed: f.seed, instance: f.instance, credentials: f.credentials)
        #expect(try #require(f.transport.lastRequest).url == expected)

        f.transport.enqueueStream(["data: [DONE]\n\n"])
        _ = try? await f.provider.stream(f.request, seed: f.seed, instance: f.instance, credentials: f.credentials)
        #expect(try #require(f.transport.lastRequest).url == expected)
    }

    @Test("the credential is sent only to the resolved endpoint")
    func credentialFollowsTheResolvedEndpoint() async throws {
        let f = try makeFixture(instanceBaseURL: Self.custom)
        await f.runBothPaths()

        // Every request that was actually made, not just the last one. A path that
        // quietly fell back to the provider default would show up here rather than
        // disappearing behind whichever request happened to be inspected.
        #expect(f.transport.requests.count == 2)
        for sent in f.transport.requests {
            #expect(
                sent.url.host == "proxy.example.com",
                """
                a request reached \(sent.url) — the credential is on it, and that host is \
                not the endpoint this run was frozen against
                """
            )
            #expect(sent.headers["Authorization"] == "Bearer sk-endpoint-probe")
        }
    }
}
