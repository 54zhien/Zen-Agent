import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer attachment")
struct ComposerAttachmentTests {
    @Test("attachmentReferenceStoresIdentityOnly")
    func attachmentReferenceStoresIdentityOnly() {
        let reference = AttachmentReference(
            id: "attachment-17",
            displayName: "scan.png",
            kind: .image
        )

        #expect(reference.id == "attachment-17")
        #expect(reference.displayName == "scan.png")
        #expect(reference.kind == .image)

        guard let body = declarationBody(named: "structAttachmentReference") else {
            Issue.record("could not read the complete AttachmentReference declaration")
            return
        }
        for forbidden in ["Data", "URL", "content", "bytes"] {
            #expect(!body.contains(forbidden), "AttachmentReference contains \(forbidden)")
        }
    }

    @Test("draftCanContainMultipleAttachmentReferences")
    func draftCanContainMultipleAttachmentReferences() {
        let attachments = [
            AttachmentReference(id: "image-1", displayName: "one.png", kind: .image),
            AttachmentReference(id: "file-2", displayName: "two.pdf", kind: .file),
            AttachmentReference(id: "image-3", displayName: "three.jpg", kind: .image),
        ]
        let draft = ComposerDraftState(
            text: "",
            selection: ComposerSelection(range: 0..<0),
            references: [],
            attachments: attachments,
            presentationState: .resting
        )

        #expect(draft.attachments.count == 3)
        #expect(draft.attachments == attachments)
    }

    @Test("attachmentReferenceDoesNotDecideCapability")
    func attachmentReferenceDoesNotDecideCapability() {
        guard let kindBody = declarationBody(named: "enumAttachmentKind"),
              let referenceBody = declarationBody(named: "structAttachmentReference") else {
            Issue.record("could not read the complete ComposerAttachment declarations")
            return
        }

        let declarations = kindBody + referenceBody
        for forbidden in ["canSend", "isSupported", "capability", "ModelCapability"] {
            #expect(!declarations.contains(forbidden), "ComposerAttachment contains \(forbidden)")
        }
    }

    private func declarationBody(named marker: String) -> String? {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return nil
        }
        let sourceURL = root.appending(path: "App/Conversation/ComposerAttachment.swift")
        guard let data = try? Data(contentsOf: sourceURL) else {
            Issue.record("could not read ComposerAttachment.swift")
            return nil
        }
        let source = normalized(String(decoding: data, as: UTF8.self))
        guard let body = balancedDeclarationBody(named: marker, in: source) else {
            Issue.record("could not locate the complete declaration body for \(marker)")
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
