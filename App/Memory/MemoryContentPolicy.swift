import Foundation

enum MemoryContentPolicy {
    static let maximumUTF8Bytes = 1_024

    static func allows(_ content: String) -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= maximumUTF8Bytes,
              content.unicodeScalars.allSatisfy({ $0.value >= 32 || [9, 10, 13].contains($0.value) })
        else { return false }
        // Unknown unlabeled secrets cannot be recognized reliably. Refuse known
        // credential shapes and speculative facts instead of saving redacted facts.
        let patterns = [
            #"(?i)(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret|authorization|cookie)\s*[\"']?\s*[:=：]"#,
            #"(?i)\bBearer\s+\S+|\bsk-[A-Za-z0-9_-]{16,}"#,
            #"(?i)\b(password|secret|token|api[_ -]?key)\s+(is|are)\b|\btoken\s*[:=]"#,
            #"(?i)https?://[^\s/]+:[^\s/]+@|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"(密码|密钥|令牌|口令|验证码|私钥)\s*(是|为|[:：=])"#,
            #"(?i)忽略.{0,12}(规则|指令)|允许所有工具|ignore.{0,20}(instructions|rules)|system prompt"#,
            #"(?i)我可能|我也许|好像|不确定|\b(maybe|perhaps|probably|might)\b"#
        ]
        return !patterns.contains { content.range(of: $0, options: .regularExpression) != nil }
    }
}
