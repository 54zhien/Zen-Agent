import Foundation

/// The real transport. **The only file in the app that mentions `URLSession`**, enforced
/// by a CI check — so any policy about how requests are made has exactly one place to
/// live, and a Provider cannot quietly acquire its own networking behaviour.
///
/// It does **no** retrying. Not on 429, not on 503, not on a dropped connection. A
/// chat completion is a POST that may already have been accepted, billed and answered by
/// the time the connection fails, so a resend here would be a second generation
/// presented to the user as the first. Retry belongs to a layer that knows about attempt
/// identity (`Agent Runtime.md:342`), and a transport that decided for itself would make
/// that decision unreachable.
struct URLSessionHTTPTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPTransportError.networkFailure("the response was not HTTP")
            }
            return HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: data)
        } catch is CancellationError {
            throw HTTPTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPTransportError.cancelled
        } catch {
            // The error's own description, never the request's. `URLError` carries the
            // failing URL and a code; a message built from the request would carry the
            // Authorization header, and this string ends up in logs.
            throw HTTPTransportError.networkFailure(Self.describe(error))
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "transport error"
        }
        // Deliberately not `urlError.localizedDescription` verbatim either: it is stable
        // enough, but the code is the part worth keeping, and the code is safe.
        return "URLError code \(urlError.errorCode)"
    }
}
