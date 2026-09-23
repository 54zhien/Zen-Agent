import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer discipline")
struct ComposerDisciplineTests {
    private static let productionDeclarationMarkers: [String: [String]] = [
        "App/Conversation/ComposerSelection.swift": [
            "structComposerSelection",
        ],
        "App/Conversation/ComposerAttachment.swift": [
            "enumAttachmentKind",
            "structAttachmentReference",
        ],
        "App/Conversation/ComposerDraftState.swift": [
            "structQuoteReference",
            "enumComposerPresentationState",
            "structComposerDraftState",
        ],
        "App/Conversation/ConversationComposerConfiguration.swift": [
            "structConversationComposerConfiguration",
        ],
        "App/Conversation/ComposerController.swift": [
            "classComposerController",
        ],
    ]

    @Test("composerDraftStateKeepsExactStorageShape")
    func composerDraftStateKeepsExactStorageShape() {
        guard let source = productionSource(at: "App/Conversation/ComposerDraftState.swift"),
              let body = completeDeclarationBody(
                named: "structComposerDraftState",
                in: normalized(source)
              ) else {
            Issue.record("could not read the complete ComposerDraftState declaration")
            return
        }

        let expected: Set<String> = [
            "text",
            "selection",
            "quoteReference",
            "attachments",
            "presentationState",
        ]
        let members = storedProperties(in: body)
        let actual = Set(members.filter { $0.isStored }.map { $0.name })

        #expect(actual == expected, "stored properties were \(actual), expected exactly \(expected)")
        #expect(body.contains("text:String"), "text must have the String type")
        #expect(
            members.first(where: { $0.name == "text" && $0.isStored })?.type == "String",
            "text must be a stored String, without a wrapper or optional"
        )
    }

    @Test("composerDraftDoesNotReachPersistenceLayer")
    func composerDraftDoesNotReachPersistenceLayer() {
        guard let sources = productionSources() else { return }
        let forbidden = ["PersistenceStore", "Database", "GRDB", "importApp/Persistence"]

        for source in sources {
            let checked = normalized(source.imports + source.declarationBodies.joined())
            for spelling in forbidden {
                #expect(
                    !checked.contains(spelling),
                    "\(source.path) contains \(spelling) in an import or declaration body"
                )
            }
        }
    }

    @Test("composerDoesNotOwnRunStateStorage")
    func composerDoesNotOwnRunStateStorage() {
        guard let controller = completeProductionDeclaration(
                file: "App/Conversation/ComposerController.swift",
                marker: "classComposerController"
              ),
              let draft = completeProductionDeclaration(
                file: "App/Conversation/ComposerDraftState.swift",
                marker: "structComposerDraftState"
              ) else {
            Issue.record("could not read the complete ComposerController and ComposerDraftState declarations")
            return
        }

        for spelling in ["RunState", "RunProjection", "AgentRuntime", "SendCommand"] {
            #expect(!controller.contains(spelling), "ComposerController contains \(spelling)")
            #expect(!draft.contains(spelling), "ComposerDraftState contains \(spelling)")
        }
    }

    @Test("composerLogicDoesNotImportSwiftUI")
    func composerLogicDoesNotImportSwiftUI() {
        guard let sources = productionSources() else { return }
        #expect(sources.count == Self.productionDeclarationMarkers.count)

        for source in sources {
            let sourceWithoutWhitespace = normalized(source.raw)
            #expect(!sourceWithoutWhitespace.contains("importSwiftUI"), "\(source.path) imports SwiftUI")
            #expect(!sourceWithoutWhitespace.contains("importUIKit"), "\(source.path) imports UIKit")
        }
    }

    private struct ProductionSource {
        let path: String
        let raw: String
        let imports: String
        let declarationBodies: [String]
    }

    private struct ParsedProperty {
        let name: String
        let type: String?
        let isStored: Bool
    }

    private func productionSources() -> [ProductionSource]? {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return nil
        }

        var result: [ProductionSource] = []
        for (path, markers) in Self.productionDeclarationMarkers.sorted(by: { $0.key < $1.key }) {
            let sourceURL = root.appending(path: path)
            guard let data = try? Data(contentsOf: sourceURL) else {
                Issue.record("could not read \(path)")
                return nil
            }
            let raw = String(decoding: data, as: UTF8.self)
            let normalizedSource = normalized(raw)
            var bodies: [String] = []
            for marker in markers {
                guard let body = completeDeclarationBody(named: marker, in: normalizedSource) else {
                    Issue.record("could not locate the complete declaration body \(marker) in \(path)")
                    return nil
                }
                bodies.append(body)
            }
            let imports = raw
                .split(whereSeparator: { $0.isNewline })
                .filter { String($0).trimmingCharacters(in: .whitespaces).hasPrefix("import ") }
                .joined()
            result.append(
                ProductionSource(
                    path: path,
                    raw: raw,
                    imports: imports,
                    declarationBodies: bodies
                )
            )
        }
        return result
    }

    private func productionSource(at path: String) -> String? {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return nil
        }
        let sourceURL = root.appending(path: path)
        guard let data = try? Data(contentsOf: sourceURL) else {
            Issue.record("could not read \(path)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func completeProductionDeclaration(file: String, marker: String) -> String? {
        guard let source = productionSource(at: file) else { return nil }
        guard let body = completeDeclarationBody(named: marker, in: normalized(source)) else {
            Issue.record("could not locate the complete declaration body \(marker) in \(file)")
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

    private func completeDeclarationBody(named marker: String, in source: String) -> String? {
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

    private func storedProperties(in body: String) -> [ParsedProperty] {
        let characters = Array(body)
        var properties: [ParsedProperty] = []
        var index = 0

        while index < characters.count {
            if characters[index] == "{" {
                index = indexAfterBalancedBody(startingAt: index, in: characters)
                continue
            }

            guard let member = memberStart(at: index, in: characters) else {
                index += 1
                continue
            }

            var cursor = member.afterName
            if cursor < characters.count, characters[cursor] == ":" {
                let typeStart = cursor + 1
                cursor = typeStart
                var squareDepth = 0
                var parenthesisDepth = 0
                var angleDepth = 0
                var foundTerminator = false

                while cursor < characters.count {
                    let character = characters[cursor]
                    if squareDepth == 0, parenthesisDepth == 0, angleDepth == 0 {
                        if character == "{" {
                            let type = String(characters[typeStart..<cursor])
                            properties.append(ParsedProperty(name: member.name, type: type, isStored: false))
                            index = indexAfterBalancedBody(startingAt: cursor, in: characters)
                            foundTerminator = true
                            break
                        }
                        if character == "=" {
                            let type = String(characters[typeStart..<cursor])
                            properties.append(ParsedProperty(name: member.name, type: type, isStored: true))
                            index = indexAfterInitializer(startingAt: cursor + 1, in: characters)
                            foundTerminator = true
                            break
                        }
                        if memberStart(at: cursor, in: characters) != nil {
                            let type = String(characters[typeStart..<cursor])
                            properties.append(ParsedProperty(name: member.name, type: type, isStored: true))
                            index = cursor
                            foundTerminator = true
                            break
                        }
                    }

                    switch character {
                    case "[": squareDepth += 1
                    case "]": squareDepth -= 1
                    case "(": parenthesisDepth += 1
                    case ")": parenthesisDepth -= 1
                    case "<": angleDepth += 1
                    case ">": angleDepth = max(0, angleDepth - 1)
                    default: break
                    }
                    cursor += 1
                }

                if !foundTerminator {
                    let type = String(characters[typeStart..<cursor])
                    properties.append(ParsedProperty(name: member.name, type: type, isStored: true))
                    index = cursor
                }
            } else if cursor < characters.count, characters[cursor] == "{" {
                properties.append(ParsedProperty(name: member.name, type: nil, isStored: false))
                index = indexAfterBalancedBody(startingAt: cursor, in: characters)
            } else if cursor < characters.count, characters[cursor] == "=" {
                properties.append(ParsedProperty(name: member.name, type: nil, isStored: true))
                index = indexAfterInitializer(startingAt: cursor + 1, in: characters)
            } else {
                properties.append(ParsedProperty(name: member.name, type: nil, isStored: true))
                index = cursor
            }
        }

        return properties
    }

    private func memberStart(
        at index: Int,
        in characters: [Character]
    ) -> (name: String, afterName: Int)? {
        for keyword in ["var", "let"] {
            let keywordCharacters = Array(keyword)
            guard index + keywordCharacters.count <= characters.count,
                  Array(characters[index..<(index + keywordCharacters.count)]) == keywordCharacters else {
                continue
            }

            let nameStart = index + keywordCharacters.count
            guard nameStart < characters.count, isIdentifierStart(characters[nameStart]) else { continue }
            var afterName = nameStart + 1
            while afterName < characters.count, isIdentifierContinuation(characters[afterName]) {
                afterName += 1
            }
            guard afterName < characters.count,
                  characters[afterName] == ":" || characters[afterName] == "=" || characters[afterName] == "{" else {
                continue
            }

            return (String(characters[nameStart..<afterName]), afterName)
        }
        return nil
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private func indexAfterBalancedBody(startingAt openingIndex: Int, in characters: [Character]) -> Int {
        var depth = 0
        var index = openingIndex
        while index < characters.count {
            if characters[index] == "{" {
                depth += 1
            } else if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return characters.count
    }

    private func indexAfterInitializer(startingAt start: Int, in characters: [Character]) -> Int {
        var curlyDepth = 0
        var squareDepth = 0
        var parenthesisDepth = 0
        var angleDepth = 0
        var insideString = false
        var escaped = false
        var index = start

        while index < characters.count {
            let character = characters[index]
            if !insideString,
               curlyDepth == 0,
               squareDepth == 0,
               parenthesisDepth == 0,
               angleDepth == 0,
               memberStart(at: index, in: characters) != nil {
                return index
            }

            if insideString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
            } else if character == "\"" {
                insideString = true
            } else {
                switch character {
                case "{": curlyDepth += 1
                case "}": curlyDepth = max(0, curlyDepth - 1)
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "(": parenthesisDepth += 1
                case ")": parenthesisDepth = max(0, parenthesisDepth - 1)
                case "<": angleDepth += 1
                case ">": angleDepth = max(0, angleDepth - 1)
                default: break
                }
            }
            index += 1
        }
        return characters.count
    }

    private func normalized(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }
}
