import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer view contract")
struct ComposerViewContractTests {
    private static let allowedSourcePaths = [
        "App/Conversation/ComposerController.swift",
        "App/Conversation/ComposerDraftState.swift",
        "App/Conversation/ComposerTextProjection.swift",
        "App/Conversation/ConversationComposerView.swift",
        "App/Conversation/ComposerTextView.swift",
        "App/Conversation/ComposerGeometry.swift",
    ]

    @Test("composerViewHasNoIndependentDraftTextStorage")
    func composerViewHasNoIndependentDraftTextStorage() {
        guard let sources = sourceFiles() else { return }
        let view = sources["App/Conversation/ConversationComposerView.swift"] ?? ""
        let bridge = sources["App/Conversation/ComposerTextView.swift"] ?? ""
        let draftStorageCount = sources.values.reduce(0) {
            $0 + $1.components(separatedBy: "var draft:").count - 1
        }
        let stateDeclarations = view
            .split(whereSeparator: { $0.isNewline })
            .filter { $0.contains("@State") }
        let independentTextStorage = stateDeclarations.filter {
            let declaration = String($0)
            return declaration.contains("String")
                || declaration.range(of: #"\b(draft|text|previewText|draftText)\b"#, options: .regularExpression) != nil
        }

        #expect(draftStorageCount == 1)
        #expect(independentTextStorage.isEmpty)
        #expect(bridge.contains("@Binding var text: String"))
        #expect(sources["App/Conversation/ComposerTextProjection.swift"] != nil)
        #expect(view.contains("ComposerTextProjection.presentation(for: controller.draft)"))
    }

    @Test("markedTextUpdatePolicyPreservesEditorBufferAndSelection")
    func markedTextUpdatePolicyPreservesEditorBufferAndSelection() {
        guard let bridge = sourceFiles()?["App/Conversation/ComposerTextView.swift"] else { return }
        let composing = ComposerTextViewUpdatePolicy.resolve(markedTextPresent: true)
        let committed = ComposerTextViewUpdatePolicy.resolve(markedTextPresent: false)

        #expect(!composing.writesText)
        #expect(!composing.writesSelection)
        #expect(committed.writesText)
        #expect(committed.writesSelection)
        #expect(bridge.contains("ComposerTextViewUpdatePolicy.resolve("))
        #expect(bridge.contains("if policy.writesText"))
        #expect(bridge.contains("if policy.writesSelection"))
    }

    @Test("allStatesConsumeOneShapeToken")
    func allStatesConsumeOneShapeToken() {
        guard let sources = sourceFiles() else { return }
        let geometry = sources["App/Conversation/ComposerGeometry.swift"] ?? ""
        let view = sources["App/Conversation/ConversationComposerView.swift"] ?? ""
        let shapeCalls = view.components(separatedBy: "ComposerShapeToken.shape(for:").count - 1

        #expect(shapeCalls == 1)
        #expect(view.contains(".contentShape(shape)"))
        #expect(geometry.contains("enum ComposerShapeToken"))
        #expect(geometry.contains("ConcentricRectangle(corners: .concentric(minimum:"))
        #expect(!view.contains("cornerRadius"))
        #expect(!view.contains("RoundedRectangle"))
    }

    private func sourceFiles() -> [String: String]? {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root from the test source path")
            return nil
        }

        var sources: [String: String] = [:]
        for path in Self.allowedSourcePaths {
            let url = root.appending(path: path)
            guard let data = try? Data(contentsOf: url) else {
                Issue.record("could not read allowed Composer source \(path)")
                return nil
            }
            sources[path] = String(decoding: data, as: UTF8.self)
        }
        return sources
    }

    private func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != directory.deletingLastPathComponent().path {
            let app = directory.appending(path: "App")
            let tests = directory.appending(path: "Tests")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: app.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               fileManager.fileExists(atPath: tests.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
