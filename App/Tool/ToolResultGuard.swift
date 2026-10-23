import Foundation

enum ToolResultKind: String, Codable, Sendable { case text, reference, error }
enum ToolResultFailure: String, Codable, Error, Sendable {
    case executionFailed, resultTooLarge, invalidResult, redactionUnavailable, dependencyUnavailable
}

/// Results remain untrusted Tool-role data. This boundary changes no policy or
/// grant; it runs before durable storage and every provider continuation.
enum ToolResultGuard {
    static let maximumUTF8Bytes = 65_536

    static func isText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 32 || [9, 10, 13].contains($0.value) }
    }

    static func sanitize(_ result: ToolExecutionResult, knownSecrets: [SecretValue]) -> ToolExecutionResult {
        guard result.content.utf8.count <= maximumUTF8Bytes else { return .failure(.resultTooLarge) }
        guard isText(result.content), (result.kind == .error) == (result.failure != nil) else { return .failure(.invalidResult) }
        if result.kind == .reference {
            guard let object = try? ToolArgumentJSON.object(from: result.content),
                  object["kind"] as? String == "managedFile", object["assetID"] is String,
                  object["versionID"] is String, object["fingerprint"] is String else { return .failure(.invalidResult) }
        }
        var text = result.content
        for secret in knownSecrets where !secret.revealed.isEmpty {
            text = text.replacingOccurrences(of: secret.revealed, with: "[REDACTED]")
            // JSON may have escaped a credential before it reached this boundary.
            if let data = try? JSONSerialization.data(withJSONObject: [secret.revealed]),
               let quoted = String(data: data, encoding: .utf8) {
                let escaped = String(quoted.dropFirst(2).dropLast(2))
                if !escaped.isEmpty { text = text.replacingOccurrences(of: escaped, with: "[REDACTED]") }
            }
        }
        let patterns: [(String, String)] = [
            (#"(?i)("(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)"\s*:\s*")[^"]*(")"#, "$1[REDACTED]$2"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}"#, "[REDACTED]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return .failure(.redactionUnavailable) }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        guard text.utf8.count <= maximumUTF8Bytes else { return .failure(.resultTooLarge) }
        return ToolExecutionResult(content: text, kind: result.kind, failure: result.failure)
    }
}
