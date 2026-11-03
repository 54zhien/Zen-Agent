import Foundation
import Testing

@testable import ZenAgent

@Suite("Web Read Redirect Policy")
struct WebReadTransportTests {
    @Test("refuses a cross-origin redirect before requesting its destination")
    func refusesCrossOriginRedirect() async throws {
        let start = URL(string: "https://start-\(UUID().uuidString).example/start")!
        let destination = URL(string: "https://destination-\(UUID().uuidString).example/final")!
        WebReadRedirectURLProtocol.configure(start: start, destination: destination)
        defer { WebReadRedirectURLProtocol.clear(start: start) }

        let transport = URLSessionHTTPTransport(session: WebReadRedirectURLProtocol.makeSession())
        do {
            _ = try await transport.stream(HTTPRequest(method: .get, url: start, redirectPolicy: .sameOrigin))
            Issue.record("Cross-origin redirect should be refused")
        } catch HTTPTransportError.httpStatus(let response) {
            #expect(response.status == 302)
            #expect(response.redirectRefusal?.sourceOrigin == "https://\(start.host!)")
            #expect(response.redirectRefusal?.destinationOrigin == "https://\(destination.host!)")
            #expect(response.redirectRefusal?.reason == .crossOrigin)
        }

        #expect(WebReadRedirectURLProtocol.requests(for: start).map(\.absoluteString) == [start.absoluteString])
        #expect(WebReadRedirectURLProtocol.requests(for: destination).isEmpty)
    }

    @Test("allows a redirect that stays on the original origin")
    func allowsSameOriginRedirect() async throws {
        let start = URL(string: "https://same-\(UUID().uuidString).example/start")!
        let destination = URL(string: "https://\(start.host!)/final")!
        WebReadRedirectURLProtocol.configure(start: start, destination: destination)
        defer { WebReadRedirectURLProtocol.clear(start: start) }

        let transport = URLSessionHTTPTransport(session: WebReadRedirectURLProtocol.makeSession())
        let stream = try await transport.stream(HTTPRequest(method: .get, url: start, redirectPolicy: .sameOrigin))
        defer { stream.cancel() }

        #expect(stream.responseHead?.finalURL == destination)
        #expect(String(decoding: try await collect(stream.body), as: UTF8.self) == "landed")
        #expect(WebReadRedirectURLProtocol.requests(for: destination).count == 1)
    }

    @Test("stops delivering a successful response at its byte limit")
    func capsSuccessfulResponseStream() async throws {
        let url = URL(string: "https://bounded-\(UUID().uuidString).example/page")!
        let transport = URLSessionHTTPTransport(session: WebReadRedirectURLProtocol.makeSession())
        let stream = try await transport.stream(HTTPRequest(
            method: .get,
            url: url,
            maximumResponseBytes: 3
        ))
        defer { stream.cancel() }

        var received = Data()
        do {
            for try await chunk in stream.body { received.append(chunk) }
            Issue.record("The stream should report that its byte limit was reached")
        } catch HTTPTransportError.streamInterrupted(let deliveredData, let reason) {
            #expect(deliveredData)
            #expect(reason == HTTPTransportError.responseBodyLimitExceededReason)
        }
        #expect(received == Data("lan".utf8))
    }

    private func collect(_ body: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var result = Data()
        for try await chunk in body { result.append(chunk) }
        return result
    }
}

private final class WebReadRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var destinations: [String: URL] = [:]
    nonisolated(unsafe) private static var requestLog: [String: [URL]] = [:]

    static func configure(start: URL, destination: URL) {
        lock.withLock {
            destinations[start.absoluteString] = destination
            requestLog[start.absoluteString] = []
            requestLog[destination.absoluteString] = []
        }
    }

    static func clear(start: URL) {
        lock.withLock {
            if let destination = destinations.removeValue(forKey: start.absoluteString) {
                requestLog.removeValue(forKey: destination.absoluteString)
            }
            requestLog.removeValue(forKey: start.absoluteString)
        }
    }

    static func requests(for url: URL) -> [URL] {
        lock.withLock { requestLog[url.absoluteString] ?? [] }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let destination = Self.lock.withLock { () -> URL? in
            Self.requestLog[url.absoluteString, default: []].append(url)
            return Self.destinations[url.absoluteString]
        }
        if let destination {
            let redirect = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("landed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
