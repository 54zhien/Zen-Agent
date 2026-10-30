import Foundation

enum ToolResultKind: String, Codable, Sendable { case text, reference, error }
enum ToolResultFailure: String, Codable, Error, Sendable {
    case executionFailed, resultTooLarge, invalidResult, redactionUnavailable, dependencyUnavailable
    case authenticationRequired, systemPermissionDenied, dependencyChanged, resourceInUse
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
        let decoded = try? JSONSerialization.jsonObject(with: Data(result.content.utf8), options: [.fragmentsAllowed])
        var text = result.content
        if let decoded {
            let redacted = redactJSON(decoded, knownSecrets: knownSecrets)
            if redacted.changed {
                guard let data = try? JSONSerialization.data(withJSONObject: redacted.value, options: [.sortedKeys, .fragmentsAllowed]),
                      let encoded = String(data: data, encoding: .utf8) else { return .failure(.redactionUnavailable) }
                text = encoded
            }
        }
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
            (#"(?i)("(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|authorization)"\s*:\s*")(?:\\.|[^"\\])*(")"#, "$1[REDACTED]$2"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}"#, "[REDACTED]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return .failure(.redactionUnavailable) }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        // A redacted identity would point at a different or nonexistent file.
        // Refuse the reference rather than publish misleading scope metadata.
        if result.kind == .reference, !text.utf8.elementsEqual(result.content.utf8) {
            return .failure(.redactionUnavailable)
        }
        guard text.utf8.count <= maximumUTF8Bytes else { return .failure(.resultTooLarge) }
        return ToolExecutionResult(content: text, kind: result.kind, failure: result.failure)
    }

    /// Decode JSON before matching: equivalent string/key encodings must not
    /// escape redaction. Preserve original bytes when nothing changed so a
    /// reference is never rewritten merely by serialization.
    private static func redactJSON(_ value: Any, knownSecrets: [SecretValue]) -> (value: Any, changed: Bool) {
        if let object = value as? [String: Any] {
            var output: [String: Any] = [:]
            var changed = false
            for (key, child) in object {
                let safeKey = redactKnownText(key, knownSecrets: knownSecrets)
                let normalized = key.lowercased().filter { $0 != "_" && $0 != "-" }
                if ["apikey", "accesstoken", "refreshtoken", "token", "password", "secret", "authorization"].contains(normalized) {
                    output[safeKey] = "[REDACTED]"
                    changed = true
                } else {
                    let result = redactJSON(child, knownSecrets: knownSecrets)
                    output[safeKey] = result.value
                    changed = changed || result.changed
                }
                changed = changed || !safeKey.utf8.elementsEqual(key.utf8)
            }
            return (output, changed)
        }
        if let array = value as? [Any] {
            let values = array.map { redactJSON($0, knownSecrets: knownSecrets) }
            return (values.map(\.value), values.contains { $0.changed })
        }
        if let string = value as? String {
            let safe = redactKnownText(string, knownSecrets: knownSecrets)
            return (safe, !safe.utf8.elementsEqual(string.utf8))
        }
        if let number = value as? NSNumber, knownSecrets.contains(where: { $0.revealed == number.stringValue }) {
            return ("[REDACTED]", true)
        }
        return (value, false)
    }

    private static func redactKnownText(_ source: String, knownSecrets: [SecretValue]) -> String {
        knownSecrets.reduce(source) { value, secret in
            secret.revealed.isEmpty ? value : value.replacingOccurrences(of: secret.revealed, with: "[REDACTED]")
        }
    }
}
