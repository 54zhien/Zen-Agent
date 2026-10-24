import Foundation

enum SkillRouter {
    static let maximumActivatedSkills = 2
    static func select(query: String, candidates: [SkillItem]) -> [SkillItem] {
        guard query.utf8.count <= 32_768 else { return [] }
        let query = normalize(query)
        guard !query.isEmpty else { return [] }
        return candidates.filter { $0.enabled && !$0.pendingDeletion }.compactMap { item -> (SkillItem, Int)? in
            let score = Set(item.definition.triggerTerms.map(normalize)).filter { term in
                guard !term.isEmpty else { return false }
                // Latin trigger words must not activate inside a different word.
                let latin = term.unicodeScalars.allSatisfy { $0.isASCII }
                if latin {
                    let expression = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9_])"
                    return query.range(of: expression, options: .regularExpression) != nil
                }
                return query.contains(term)
            }.count
            return score > 0 ? (item, score) : nil
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
        }.prefix(maximumActivatedSkills).map { $0.0 }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
