import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer selection")
struct ComposerSelectionTests {
    @Test("selectionRepresentsCursorWhenRangeIsEmpty")
    func selectionRepresentsCursorWhenRangeIsEmpty() {
        let selection = ComposerSelection(range: 3..<3)

        #expect(selection.range == 3..<3)
        #expect(selection.range.isEmpty)
    }

    @Test("selectionRepresentsTextRange")
    func selectionRepresentsTextRange() {
        let selection = ComposerSelection(range: 2..<8)

        #expect(selection.range.lowerBound == 2)
        #expect(selection.range.upperBound == 8)
    }

    @Test("selectionDoesNotOwnText")
    func selectionDoesNotOwnText() {
        guard let body = declarationBody() else {
            Issue.record("could not read the complete ComposerSelection declaration")
            return
        }

        #expect(!body.contains("String"))
    }

    private func declarationBody() -> String? {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return nil
        }
        let sourceURL = root.appending(path: "App/Conversation/ComposerSelection.swift")
        guard let data = try? Data(contentsOf: sourceURL) else {
            Issue.record("could not read ComposerSelection.swift")
            return nil
        }
        let source = normalized(String(decoding: data, as: UTF8.self))
        guard let body = balancedDeclarationBody(named: "structComposerSelection", in: source) else {
            Issue.record("could not locate the complete ComposerSelection declaration body")
            return nil
        }
        return body
    }

    private func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        for _ in 0..<8 {
            var isDirectory: ObjCBool = false
            let hasApp = FileManager.default.fileExists(
                atPath: directory.appending(path: "App").path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            let hasTests = FileManager.default.fileExists(
                atPath: directory.appending(path: "Tests").path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue

            if hasApp && hasTests { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private func balancedDeclarationBody(named marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var bodyStart: String.Index?
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
                if depth == 1 { bodyStart = source.index(after: index) }
            case "}":
                depth -= 1
                if depth == 0, let bodyStart {
                    return String(source[bodyStart..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func normalized(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }
}
