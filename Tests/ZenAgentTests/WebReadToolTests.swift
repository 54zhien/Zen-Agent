import Foundation
import Testing

@testable import ZenAgent

@Suite("Web Read Tool")
struct WebReadToolTests {
    private func context() -> ToolPreparationContext {
        ToolPreparationContext(requestConfigSeed: RequestConfigSeed(
            providerInstanceID: ProviderInstanceID(rawValue: "provider-1"),
            modelID: ModelID(rawValue: "model-1"),
            providerConfigRevision: .initial,
            credentialBinding: CredentialBindingSnapshot(
                reference: CredentialReference(id: "credential-1"), generation: 1
            ),
            resolvedEndpoint: URL(string: "https://api.example.com/v1/chat/completions")!
        ))
    }

    @Test("freezes the page origin and Provider endpoint for one explicit approval")
    func preparationFreezesDisclosureAndApproval() throws {
        let tool = WebReadTool(transport: WebReadRecordingTransport(body: Data()))
        let context = context()
        let intent = try tool.prepare(
            callID: "web-call",
            argumentsJSON: #"{"url":"https://www.example.com/articles/one?private=value"}"#,
            context: context
        )

        #expect(tool.descriptor.approvalRequirement == .required)
        #expect(intent.policyAction?.risk == .high)
        #expect(intent.policyAction?.allowsAutomaticApproval == false)
        #expect(intent.policyAction?.allowsConversationGrant == false)
        #expect(intent.policyAction?.egressRequirement == .webOriginRequiringApproval)
        #expect(intent.destinationScope == .webOrigin(
            pageOrigin: "https://www.example.com",
            providerInstanceID: "provider-1",
            providerEndpointIdentity: context.requestConfigSeed.endpoint.absoluteString
        ))
        #expect(intent.approvalDisclosure?.targetDescription.contains("private=value") == false)
        #expect(intent.approvalDisclosure?.keyImpact.contains("https://www.example.com") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains(context.requestConfigSeed.endpoint.absoluteString) == true)
    }

    @Test("accepts only anonymous HTTPS page URLs")
    func rejectsHTTPAndCredentialBearingURLs() throws {
        let tool = WebReadTool(transport: WebReadRecordingTransport(body: Data()))
        for value in ["http://www.example.com/page", "https://user:pass@www.example.com/page"] {
            do {
                _ = try tool.prepare(
                    callID: "web-call",
                    argumentsJSON: try ToolArgumentJSON.normalizedObject(["url": value]),
                    context: context()
                )
                Issue.record("Expected unsupported URL to be rejected")
            } catch ToolIntentFailure.invalidArguments {
            }
        }
    }

    @Test("reads anonymous HTTPS text and returns a query-redacted source")
    func executionReadsPageAndReturnsSource() async throws {
        let url = URL(string: "https://www.example.com/articles/one?private=value")!
        let transport = WebReadRecordingTransport(
            body: Data("<html><body><h1>Hello</h1><p>world &amp; reader</p></body></html>".utf8),
            headers: ["Content-Type": "text/html; charset=utf-8"],
            finalURL: url
        )
        let tool = WebReadTool(transport: transport)
        let context = context()
        let intent = try tool.prepare(
            callID: "web-call",
            argumentsJSON: #"{"url":"https://www.example.com/articles/one?private=value"}"#,
            context: context
        )

        let result = try await tool.execute(intent, idempotencyKey: "web-call")
        let request = try #require(transport.requestsSnapshot().first)

        #expect(request.method == .get)
        #expect(request.url == url)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["Cookie"] == nil)
        #expect(request.maximumResponseBytes == ToolResultGuard.maximumUTF8Bytes)
        #expect(result.content.contains("Hello"))
        #expect(result.content.contains("world & reader"))
        #expect(result.content.contains("https://www.example.com/articles/one"))
        #expect(result.content.contains("private=value") == false)
        #expect(transport.cancelCount == 1)
    }

    @Test("caps the downloaded body and ends the stream")
    func executionCapsDownloadedBody() async throws {
        let url = URL(string: "https://www.example.com/large")!
        let transport = WebReadRecordingTransport(
            body: Data(repeating: 65, count: ToolResultGuard.maximumUTF8Bytes + 1),
            headers: ["Content-Type": "text/plain"],
            finalURL: url
        )
        let tool = WebReadTool(transport: transport)
        let intent = try tool.prepare(
            callID: "web-call",
            argumentsJSON: #"{"url":"https://www.example.com/large"}"#,
            context: context()
        )

        let result = try await tool.execute(intent, idempotencyKey: "web-call")

        #expect(result.failure == .resultTooLarge)
        #expect(transport.cancelCount == 1)
    }

    @Test("request diagnostics omit query values")
    func requestDescriptionRedactsQuery() {
        let request = HTTPRequest(
            method: .get,
            url: URL(string: "https://www.example.com/page?token=private-value")!
        )

        #expect(request.description.contains("private-value") == false)
        #expect(request.description.contains("https://www.example.com/page"))
    }
}

private final class WebReadRecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    private var cancellations = 0
    private let body: Data
    private let headers: [String: String]
    private let finalURL: URL

    init(body: Data, headers: [String: String] = ["Content-Type": "text/plain"], finalURL: URL? = nil) {
        self.body = body
        self.headers = headers
        self.finalURL = finalURL ?? URL(string: "https://www.example.com/")!
    }

    var cancelCount: Int { lock.withLock { cancellations } }

    func requestsSnapshot() -> [HTTPRequest] { lock.withLock { requests } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        return HTTPResponse(status: 200, body: body)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        lock.withLock { requests.append(request) }
        let body = self.body
        let head = HTTPResponseHead(status: 200, headers: headers, finalURL: finalURL)
        return HTTPStream(
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            },
            responseHead: head,
            cancel: { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.cancellations += 1 }
            }
        )
    }
}
