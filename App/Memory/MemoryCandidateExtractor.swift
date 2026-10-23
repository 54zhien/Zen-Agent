import Foundation

struct MemoryCandidate: Sendable, Equatable {
    let content: String
    let factKey: String?
    let origin: MemoryOrigin
}

/// Deliberately narrow local recognition: unsupported wording stays in the chat.
enum MemoryCandidateExtractor {
    static let maximumSourceUTF8Bytes = 8_192
    static let maximumCandidates = 3

    static func extract(_ text: String) -> [MemoryCandidate] {
        guard text.utf8.count <= maximumSourceUTF8Bytes,
              MemoryContentPolicy.allows(text, maximumUTF8Bytes: maximumSourceUTF8Bytes),
              text.range(of: #"[\"“”‘’`>？?]|(?i:\b(today|tonight|temporarily|used to|said|translate)\b)|今天|这次|暂时|翻译|他说|她说"#,
                         options: .regularExpression) == nil else { return [] }
        var candidates: [MemoryCandidate] = []
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: "\n。!！")) {
            var value = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix(".") { value.removeLast() }
            let explicit = value.range(of: #"^(?i:remember(?: that)?\s*[:：]?\s*)|^记住\s*[:：]?\s*"#, options: .regularExpression)
            if let explicit { value.removeSubrange(explicit) }
            guard let fact = recognize(value) else { continue }
            candidates.append(MemoryCandidate(content: fact.1, factKey: fact.0, origin: explicit == nil ? .automatic : .explicitUser))
        }
        // Two incompatible assertions in the same source provide no safe winner.
        let conflicted = Set(Dictionary(grouping: candidates, by: \.factKey).compactMap { key, group in
            Set(group.map(\.content)).count > 1 ? key : nil
        })
        var seen = Set<String>()
        return Array(candidates.filter { !conflicted.contains($0.factKey ?? "") && seen.insert($0.content).inserted }.prefix(maximumCandidates))
    }

    private static func recognize(_ value: String) -> (String, String)? {
        let rules: [(String, String, String)] = [
            (#"^(?:我偏好|我喜欢|请始终用)(中文|英文)(?:回答)?$|^(?i:I prefer (Chinese|English) (?:responses|answers))$"#, "response.language", "language"),
            (#"^我偏好(简洁|详细)回答$|^(?i:I prefer (concise|detailed) (?:responses|answers))$"#, "response.length", "length"),
            (#"^我平时使用 (Windows|macOS|Linux) 开发$|^(?i:I usually develop on (Windows|macOS|Linux))$"#, "environment.os", "os"),
            (#"^我的名字是 ([\p{L}\p{N} _-]{1,60})$|^(?i:my name is ([\p{L}\p{N} _-]{1,60}))$"#, "identity.name", "name"),
            (#"^我的主要项目是 ([\p{L}\p{N} _.-]{1,80})$|^(?i:my main project is ([\p{L}\p{N} _.-]{1,80}))$"#, "project.primary", "project")
        ]
        for (pattern, key, kind) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = (1..<match.numberOfRanges).compactMap({ Range(match.range(at: $0), in: value) }).first else { continue }
            let captured = String(value[range]).trimmingCharacters(in: .whitespaces)
            let fact: String
            switch kind {
            case "language": fact = "用户偏好使用\(["中文", "chinese"].contains(captured.lowercased()) ? "中文" : "英文")回答。"
            case "length": fact = "用户偏好\(["简洁", "concise"].contains(captured.lowercased()) ? "简洁" : "详细")的回答。"
            case "os":
                let os = ["windows": "Windows", "macos": "macOS", "linux": "Linux"][captured.lowercased()] ?? captured
                fact = "用户平时使用 \(os) 开发。"
            case "name": fact = "用户的名字是 \(captured)。"
            default: fact = "用户的主要项目是 \(captured)。"
            }
            return (key, fact)
        }
        return nil
    }
}
