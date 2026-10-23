import Foundation

enum EnvironmentValidation {
    static let maximumPlainUTF8Bytes = 16_384

    static func allowsKey(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy { $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    static func allowsPlain(_ value: String) -> Bool {
        guard value.utf8.count <= maximumPlainUTF8Bytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 || [9, 10, 13].contains($0.value) }) else { return false }
        return parsedReferences(in: value) != nil
    }

    static func references(in value: String) -> [String] { parsedReferences(in: value) ?? [] }

    private static func parsedReferences(in value: String) -> [String]? {
        var result = Set<String>()
        var remainder = value[...]
        while let opening = remainder.range(of: "${") {
            let suffix = remainder[opening.upperBound...]
            guard let closing = suffix.firstIndex(of: "}") else { return nil }
            let key = String(suffix[..<closing])
            guard allowsKey(key) else { return nil }
            result.insert(key)
            remainder = suffix[suffix.index(after: closing)...]
        }
        return result.sorted()
    }
}
