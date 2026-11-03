import Foundation
import GRDB

struct ConversationSearchText: Sendable {
    struct MatchSnippet: Equatable, Sendable {
        let text: String
        let ranges: [Range<Int>]
    }

    private struct Segment: Sendable {
        let indexedBytes: Range<Int>
        let sourceCharacters: Range<Int>
    }

    private struct TermOffset {
        let term: Int
        let bytes: Range<Int>
    }

    private let sourceCharacters: [Character]
    private let segments: [Segment]
    let indexedText: String

    init(_ source: String) {
        sourceCharacters = Array(source)
        var indexed = String()
        indexed.reserveCapacity(source.utf8.count + sourceCharacters.count * 3)
        var indexedByteCount = 0
        var mappedSegments: [Segment] = []
        var previousWasToken = false
        var previousWasCJK = false

        for (offset, character) in sourceCharacters.enumerated() {
            let isToken = character.isLetter || character.isNumber
            let isCJK = Self.isCJK(character)
            if previousWasToken && isToken && (previousWasCJK || isCJK) {
                indexed.append(contentsOf: Self.separator)
                indexedByteCount += Self.separator.utf8.count
            }

            let value = String(character)
            let byteCount = value.utf8.count
            indexed.append(contentsOf: value)
            mappedSegments.append(Segment(
                indexedBytes: indexedByteCount..<(indexedByteCount + byteCount),
                sourceCharacters: offset..<(offset + 1)
            ))
            indexedByteCount += byteCount
            previousWasToken = isToken
            previousWasCJK = isCJK
        }

        indexedText = indexed
        segments = mappedSegments
    }

    static func normalized(_ source: String) -> String {
        ConversationSearchText(source).indexedText
    }

    static func registerSQLiteFunction(in db: Database) {
        db.add(function: DatabaseFunction("zen_conversation_search_text", argumentCount: 1, pure: true) { values in
            guard let text = String.fromDatabaseValue(values[0]) else { return nil }
            return ConversationSearchText.normalized(text)
        })
    }

    func snippet(offsets: String, textColumnIndex: Int) -> MatchSnippet? {
        let values = offsets.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        var groups: [[TermOffset]] = []
        var currentGroup: [TermOffset] = []
        var previousTerm: Int?

        for index in stride(from: 0, to: values.count, by: 4) {
            let column = values[index]
            let term = values[index + 1]
            let start = values[index + 2]
            let length = values[index + 3]
            guard column == textColumnIndex else { continue }

            if let previousTerm, term <= previousTerm {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(TermOffset(term: term, bytes: start..<(start + length)))
            previousTerm = term
        }
        if !currentGroup.isEmpty { groups.append(currentGroup) }

        guard let firstGroup = groups.first else { return nil }
        let hitRanges = firstGroup.compactMap { sourceRange(forIndexedBytes: $0.bytes) }
        guard let firstHit = hitRanges.min(by: { $0.lowerBound < $1.lowerBound }),
              let lastHit = hitRanges.max(by: { $0.upperBound < $1.upperBound }) else { return nil }

        let snippetStart = max(0, firstHit.lowerBound - 40)
        let snippetEnd = min(sourceCharacters.count, lastHit.upperBound + 60)
        let hasLeadingEllipsis = snippetStart > 0
        var snippetCharacters: [Character] = []
        if hasLeadingEllipsis { snippetCharacters.append("…") }
        snippetCharacters.append(contentsOf: sourceCharacters[snippetStart..<snippetEnd])
        let hasTrailingEllipsis = snippetEnd < sourceCharacters.count
        if hasTrailingEllipsis { snippetCharacters.append("…") }

        let prefixLength = hasLeadingEllipsis ? 1 : 0
        let ranges = Self.mergedRanges(hitRanges.compactMap { range in
            let lower = max(range.lowerBound, snippetStart)
            let upper = min(range.upperBound, snippetEnd)
            guard lower < upper else { return nil }
            return (lower - snippetStart + prefixLength)..<(upper - snippetStart + prefixLength)
        })
        return MatchSnippet(text: String(snippetCharacters), ranges: ranges)
    }

    private func sourceRange(forIndexedBytes bytes: Range<Int>) -> Range<Int>? {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].indexedBytes.upperBound <= bytes.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var lower: Int?
        var upper = 0
        var index = low
        while index < segments.count, segments[index].indexedBytes.lowerBound < bytes.upperBound {
            if segments[index].indexedBytes.overlaps(bytes) {
                lower = min(lower ?? segments[index].sourceCharacters.lowerBound,
                            segments[index].sourceCharacters.lowerBound)
                upper = max(upper, segments[index].sourceCharacters.upperBound)
            }
            index += 1
        }
        guard let lower else { return nil }
        return lower..<upper
    }

    private static func mergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x2E80...0x2FFF).contains(value)
            || (0x3000...0x30FF).contains(value)
            || (0x3100...0x31FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xAC00...0xD7FF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF66...0xFF9D).contains(value)
            || (0x20000...0x323AF).contains(value)
    }

    private static let separator = "\u{2063}"
}
