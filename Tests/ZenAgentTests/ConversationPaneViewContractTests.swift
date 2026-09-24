import Foundation
import SwiftUI
import Testing

@testable import ZenAgent

@Suite("Reusable conversation pane view contract")
@MainActor
struct ConversationPaneViewContractTests {

    @Test
    func twoPaneViewKeepsApprovalInsideItsPane() throws {
        let paneA = try makePane(conversationID: "view-owner-a")
        let paneB = try makePane(conversationID: "view-owner-b")
        let runtime = ConversationRuntime(
            store: PersistenceStore(database: try ZenDatabase.inMemory()),
            provider: FakeProvider(),
            credentials: CredentialStore(
                secrets: InMemorySecretBackend(),
                metadataRepository: InMemoryCredentialMetadataRepository()
            ),
            toolRegistry: ToolRegistry.empty
        )
        let actionBridge = ComposerRuntimeActionBridge(runtime: runtime)

        let viewA = ConversationPaneView(
            pane: paneA,
            runtime: runtime,
            actionBridge: actionBridge,
            maxProviderSteps: 4
        )
        let viewB = ConversationPaneView(
            pane: paneB,
            runtime: runtime,
            actionBridge: actionBridge,
            maxProviderSteps: 4
        )
        let composerA = ConversationComposerView(
            conversationID: paneA.conversationID,
            controller: paneA.composer,
            bridge: actionBridge,
            maxProviderSteps: 4
        )
        let composerB = ConversationComposerView(
            conversationID: paneB.conversationID,
            controller: paneB.composer,
            bridge: actionBridge,
            maxProviderSteps: 4
        )

        #expect(viewA.pane.conversationID == "view-owner-a")
        #expect(viewB.pane.conversationID == "view-owner-b")
        #expect(viewA.pane.composer !== viewB.pane.composer)
        #expect(composerA.conversationID == viewA.pane.conversationID)
        #expect(composerB.conversationID == viewB.pane.conversationID)
        #expect(composerA.controller === viewA.pane.composer)
        #expect(composerB.controller === viewB.pane.composer)

        let paneSource = try #require(sourceFile("App/Conversation/ConversationPaneView.swift"))
        let timelineSource = try #require(sourceFile("App/Conversation/ConversationTimelineView.swift"))
        let paneBody = try #require(blockBody(in: paneSource, after: "var body: some View"))
        let rootIdentifier = #".accessibilityIdentifier("conversation-pane-\(pane.conversationID)")"#
        let approvalIdentifier = #".accessibilityIdentifier("conversation-pane-approval-\(pane.conversationID)")"#

        #expect(paneBody.contains(rootIdentifier))
        #expect(paneBody.contains(approvalIdentifier))
        #expect(paneBody.contains("ConversationComposerView("))
        #expect(paneBody.contains("conversationID: pane.conversationID"))
        #expect(paneBody.contains("controller: pane.composer"))
        #expect(!timelineSource.contains(".sheet("))
    }

    private func makePane(conversationID: String) throws -> ConversationPaneController {
        try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "view-test-provider"),
                modelID: ModelID(rawValue: "view-test-model")
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            tolerance: 12,
            loadTimeline: { requestedConversationID in
                ConversationTimelineProjection(conversationID: requestedConversationID, turns: [])
            }
        )
    }

    private func sourceFile(_ relativePath: String) -> String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != directory.deletingLastPathComponent().path {
            let appDirectory = directory.appending(path: "App")
            let testDirectory = directory.appending(path: "Tests")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: appDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               fileManager.fileExists(atPath: testDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               let source = try? String(
                contentsOf: directory.appending(path: relativePath),
                encoding: .utf8
               ) {
                return source
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private func blockBody(in source: String, after marker: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var body = ""
        for character in source[openingBrace...] {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
        }
        return nil
    }
}
