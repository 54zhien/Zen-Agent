import Foundation

enum WebPageTextExtractor {
    static func extract(_ data: Data, contentType: String?) -> String? {
        guard let contentType else { return nil }
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mediaType, let source = String(data: data, encoding: .utf8) else { return nil }

        return switch mediaType {
        case "text/plain": normalize(source)
        case "text/html", "application/xhtml+xml": htmlText(source)
        default: nil
        }
    }

    private static func htmlText(_ source: String) -> String {
        var text = source
        text = replacing(#"(?is)<!--.*?-->"#, in: text, with: " ")
        text = replacing(#"(?is)<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#, in: text, with: " ")
        text = replacing(#"(?i)<\s*(br|/p|/div|/li|/h[1-6]|/section|/article|/tr|/blockquote)\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"(?s)<[^>]*>"#, in: text, with: " ")
        text = decodeEntities(text)
        return normalize(text)
    }

    private static func normalize(_ source: String) -> String {
        let linePattern = try? NSRegularExpression(pattern: #"[\t\x0B\f\r ]+"#)
        let blankPattern = try? NSRegularExpression(pattern: #"\n{3,}"#)
        let normalizedLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                guard let linePattern else { return line.trimmingCharacters(in: .whitespacesAndNewlines) }
                let range = NSRange(line.startIndex..., in: line)
                return linePattern.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")
        guard let blankPattern else { return normalizedLines.trimmingCharacters(in: .whitespacesAndNewlines) }
        let range = NSRange(normalizedLines.startIndex..., in: normalizedLines)
        return blankPattern.stringByReplacingMatches(in: normalizedLines, range: range, withTemplate: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"&(#(?:x[0-9a-f]+|[0-9]+)|amp|lt|gt|quot|apos|nbsp);"#,
            options: [.caseInsensitive]
        ) else { return source }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var result = source
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let entityRange = Range(match.range(at: 1), in: result) else { continue }
            let entity = String(result[entityRange]).lowercased()
            let replacement: String?
            switch entity {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = " "
            default:
                let digits = entity.dropFirst(entity.hasPrefix("#x") ? 2 : 1)
                let value = UInt32(digits, radix: entity.hasPrefix("#x") ? 16 : 10)
                replacement = value.flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }

    private static func replacing(_ pattern: String, in source: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return expression.stringByReplacingMatches(in: source, range: range, withTemplate: template)
    }
}
