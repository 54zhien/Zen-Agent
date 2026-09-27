import Foundation

enum LiveHTTPTransport {
    static func make() -> any HTTPTransport {
        URLSessionHTTPTransport()
    }
}
