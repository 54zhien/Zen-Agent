import Foundation

enum MemoryRetriever {
    static let maximumRecords = 6
    static let maximumCombinedUTF8Bytes = 4_096

    static func select(query: String, records: [MemoryItem]) -> [MemoryItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let queryTerms = terms(query)
        let ranked = records.compactMap { record -> (MemoryItem, Int)? in
            guard !record.archived, record.content.utf8.count <= 1_024 else { return nil }
            let applicablePreference = ["response.language", "response.length"].contains(record.factKey ?? "")
            let score = terms(record.content).intersection(queryTerms).count * 10 + (applicablePreference ? 3 : 0)
            return score > 0 ? (record, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id < $1.0.id
        }
        var selected: [MemoryItem] = []
        var bytes = 0
        for (record, _) in ranked {
            guard selected.count < maximumRecords else { break }
            guard bytes + record.content.utf8.count <= maximumCombinedUTF8Bytes else { continue }
            selected.append(record); bytes += record.content.utf8.count
        }
        return selected
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func terms(_ text: String) -> Set<String> {
        let text = normalized(text)
        let ignored: Set<String> = ["i", "my", "me", "we", "a", "an", "the", "is", "am", "are", "to", "on", "in", "for", "of", "and", "or", "please", "use", "prefer", "like", "work", "我偏", "偏好", "我喜", "喜欢", "我使", "使用", "项目", "记住", "请用"]
        var output: Set<String> = []
        if let regex = try? NSRegularExpression(pattern: "[a-z0-9_]{2,}") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { output.insert(String(text[range])) }
            }
        }
        // Consecutive Han bigrams work without a vendor tokenizer or a derived
        // index. Gaps and punctuation cannot manufacture cross-word matches.
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if (0x3400...0x9fff).contains(scalar.value) {
                if let previous { output.insert(String(previous) + String(scalar)) }
                previous = scalar
            } else { previous = nil }
        }
        return output.subtracting(ignored)
    }
}
