import Foundation
import GRDB

struct ConversationSearchText: Sendable {
    // FTS4 writes these markers into snippet text, so source occurrences are escaped before indexing.
    static let startMarker = "\u{0001}"
    static let endMarker = "\u{0002}"
    static let ellipsisMarker = "\u{0003}"

    struct MatchSnippet: Equatable, Sendable {
        let text: String
        let ranges: [Range<Int>]
    }

    let indexedText: String

    init(_ source: String) {
        let sourceCharacters = Array(source)
        var indexed = String()
        indexed.reserveCapacity(source.utf8.count + sourceCharacters.count * 3)
        var previousWasToken = false
        var previousWasCJK = false

        for character in sourceCharacters {
            let isToken = character.isLetter || character.isNumber
            let isCJK = Self.isCJK(character)
            if previousWasToken && isToken && (previousWasCJK || isCJK) {
                indexed.append(Self.separator)
            }

            for scalar in character.unicodeScalars {
                if Self.isSnippetControl(scalar.value) {
                    indexed.append(Self.escape)
                }
                indexed.unicodeScalars.append(scalar)
            }

            previousWasToken = isToken
            previousWasCJK = isCJK
        }

        indexedText = indexed
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

    static func snippet(from markedText: String) -> MatchSnippet {
        let scalars = Array(markedText.unicodeScalars)
        var displayedScalars: [Unicode.Scalar] = []
        var scalarRanges: [Range<Int>] = []
        var matchStart: Int?
        var index = 0

        while index < scalars.count {
            let value = scalars[index].value
            switch value {
            case 0x1F:
                index += 1
                displayedScalars.append(scalars[index])
            case 0x01:
                matchStart = displayedScalars.count
            case 0x02:
                if let matchStart, matchStart < displayedScalars.count {
                    scalarRanges.append(matchStart..<displayedScalars.count)
                }
                matchStart = nil
            case 0x03:
                displayedScalars.append("…")
            case 0x2063:
                break
            default:
                displayedScalars.append(scalars[index])
            }
            index += 1
        }

        let text = String(String.UnicodeScalarView(displayedScalars))
        let characterByScalar = text.enumerated().flatMap { characterIndex, character in
            repeatElement(characterIndex, count: character.unicodeScalars.count)
        }
        let characterRanges = scalarRanges.map { range in
            characterByScalar[range.lowerBound]..<(characterByScalar[range.upperBound - 1] + 1)
        }
        return MatchSnippet(text: text, ranges: mergedRanges(characterRanges))
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

    private static func isSnippetControl(_ scalar: UInt32) -> Bool {
        scalar == 0x2063 || scalar == 0x1F || scalar == 0x01 || scalar == 0x02 || scalar == 0x03
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x2E80...0x2FFF).contains(value)
            || (0x3000...0x30FF).contains(value)
            || (0x3100...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xAC00...0xD7FF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF66...0xFF9D).contains(value)
            || (0x20000...0x323AF).contains(value)
    }

    private static let separator = "\u{2063}"
    private static let escape = "\u{001F}"
}
