import Foundation
import Testing

@testable import ZenAgent

@Suite("Reading position discipline")
struct ReadingPositionDisciplineTests {
    private static let conversationDirectory = "App/Conversation"

    @Test("mergedTimelineTypesKeepTheirShape")
    func mergedTimelineTypesKeepTheirShape() {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return
        }

        let timelineURL = root.appending(path: "App/Conversation/ConversationTimeline.swift")
        guard let data = try? Data(contentsOf: timelineURL) else {
            Issue.record("could not read (timelineURL.path)")
            return
        }

        let source = normalized(String(decoding: data, as: UTF8.self))
        guard let enumSlice = declarationSlice(named: "enumTimelineItem", in: source) else {
            Issue.record("could not locate the TimelineItem declaration body")
            return
        }
        guard let turnSlice = declarationSlice(named: "structConversationTurn", in: source) else {
            Issue.record("could not locate the ConversationTurn declaration body")
            return
        }

        for requiredCase in [
            "caseuserText(String)",
            "caseassistantText(String)",
            "casereasoning(String)",
            "casetoolCall(ToolCallPresentation)",
            "casetoolResult(ToolResultPresentation)",
            "caserunNotice(RunNoticePresentation)"
        ] {
            #expect(enumSlice.contains(requiredCase), "TimelineItem is missing (requiredCase)")
        }
        #expect(!enumSlice.contains("TimelineItemID"))
        #expect(!enumSlice.contains("caseid("))

        #expect(turnSlice.contains("letrunID:String"))
        #expect(turnSlice.contains("letitems:[TimelineItem]"))
        #expect(turnSlice.contains("varid:String{runID}"))
    }

    @Test("readingPositionLogicDoesNotImportSwiftUI")
    func readingPositionLogicDoesNotImportSwiftUI() {
        guard let root = repositoryRoot() else {
            Issue.record("could not locate repository root by walking up from #filePath")
            return
        }

        let directory = root.appending(path: Self.conversationDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            Issue.record("could not read (directory.path)")
            return
        }

        let logicFiles = contents
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix("ReadingPosition") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !logicFiles.isEmpty else {
            Issue.record("no ReadingPosition*.swift files found in (directory.path)")
            return
        }

        for file in logicFiles {
            guard let data = try? Data(contentsOf: file) else {
                Issue.record("could not read (file.path)")
                continue
            }
            #expect(
                !normalized(String(decoding: data, as: UTF8.self)).contains("importSwiftUI"),
                "(file.lastPathComponent) must remain independent of SwiftUI"
            )
        }
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

    private func declarationSlice(named marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        let bodyStart = start.upperBound
        guard let end = source[bodyStart...].firstIndex(of: "}") else { return nil }
        return String(source[start.lowerBound...end])
    }

    private func normalized(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }
}
