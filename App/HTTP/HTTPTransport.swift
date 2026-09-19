import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

/// A request as the transport layer sees it.
///
/// **Self-redacting.** This type carries the `Authorization` header — it has to, that is
/// what it is for — so the danger is not that the secret is here but that it gets
/// printed. A crash report, a network log, a `print` someone left behind: all of them
/// walk a struct's fields, which is why `customMirror` is needed and not just a nicer
/// `description`.
///
/// Same technique as `SecretValue`, for the same reason, in the one other place a secret
/// is legitimately in memory.
struct HTTPRequest: Sendable {
    var method: HTTPMethod
    var url: URL
    var headers: [String: String]
    var body: Data?

    init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Header names whose values never appear in diagnostics.
    ///
    /// Compared case-insensitively: HTTP header names are, and `Authorization` and
    /// `authorization` are the same header.
    static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
    ]

    static func isSensitive(header name: String) -> Bool {
        sensitiveHeaderNames.contains(name.lowercased())
    }

    /// The headers with sensitive values replaced. Safe to log.
    var redactedHeaders: [String: String] {
        headers.mapValues { _ in "<redacted>" }
            .merging(
                headers.filter { !Self.isSensitive(header: $0.key) },
                uniquingKeysWith: { _, safe in safe }
            )
    }
}

extension HTTPRequest: CustomStringConvertible {
    var description: String {
        "\(method.rawValue) \(url.absoluteString) headers=\(redactedHeaders)"
    }
}

extension HTTPRequest: CustomDebugStringConvertible {
    var debugDescription: String { description }
}

extension HTTPRequest: CustomReflectable {
    /// Empty mirror, so reflecting into a *containing* value cannot reach the headers
    /// either. This is the one that actually matters: `String(describing:)` on a struct
    /// with an `HTTPRequest` field walks into it.
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Convenience for the fakes, which describe responses as text.
    init(status: Int, headers: [String: String] = [:], json: String) {
        self.init(status: status, headers: headers, body: Data(json.utf8))
    }
}

enum HTTPTransportError: Error, Equatable {
    /// The request never completed. The message is the underlying description, which
    /// must not contain request headers — see `URLSessionHTTPTransport`.
    case networkFailure(String)
    case cancelled
}

/// The seam a Provider is written against.
///
/// Deliberately small: method, URL, headers, body in; status, headers, body out. Enough
/// for a Provider transport and nothing more — no retry policy, no interceptors, no
/// middleware chain. A general networking framework built before there are three users
/// of it is a framework shaped by the first one (`开发规划.md:462-473`).
///
/// `URLSession` never appears above this protocol, which a CI check enforces.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
