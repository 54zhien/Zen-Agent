import Foundation
import GRDB
import SwiftUI
import UIKit
import Testing

@testable import ZenAgent

enum ShellCredentialSeed: Equatable, Sendable {
    case none
    case active
    case missingSecret
    case unreadableSecret
}

private enum RouterLoadFailure: Error {
    case unavailable
}

@Suite("App shell wiring")
@MainActor
struct AppShellWiringTests {
    @Test("an unchanged final Split ratio retains the layout revision already measured by both Panes")
    func unchangedSplitRatioKeepsMeasuredRevision() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        fixture.model.setSplitRatio(0.63)
        let measured = fixture.model.workspaceLayoutRevision
        fixture.model.setSplitRatio(0.63)
        #expect(fixture.model.workspaceLayoutRevision == measured)
        fixture.model.setSplitRatio(0.55)
        #expect(fixture.model.workspaceLayoutRevision > measured)
    }

    @Test("New from a Single Card clears its preview physical slot before a subsequent Split")
    func singleCardNewClearsPreviewSurfaceSlot() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in try Fixtures.conversation(id: "single-card-new").insert(db) }
        #expect(await fixture.model.openConversation(id: "single-card-new"))
        #expect(fixture.model.enterPreview())
        #expect(fixture.model.previewSurfaceSlot == .primary)
        fixture.model.newConversation()
        #expect(!fixture.model.previewContent.isPresented)
        #expect(fixture.model.previewSurfaceSlot == nil,
            "Single cleanup must clear the Card's owner too; a stale active slot suppresses the Split picker")
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
    }
    @Test("source Recent preserves a ratio changed while its history read is suspended")
    func sourceRecentKeepsConcurrentResizeRatio() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "ratio-kept-other").insert(db)
            try Fixtures.conversation(id: "ratio-replacement").insert(db)
        }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "ratio-kept-other"))
        fixture.model.setSplitRatio(0.55)
        let other = try #require(fixture.model.splitPane)
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let opening = Task { await fixture.model.openConversation(id: "ratio-replacement") }
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.hasBlocked)
        fixture.model.setSplitRatio(0.63)
        gate.release()
        #expect(await opening.value)
        #expect(fixture.model.splitWorkspace?.topBottomRatio == 0.63)
        #expect(fixture.model.splitPane === other)
    }

    @Test("cancelled Divider drag rolls back only its original live arrangement")
    func dividerCancellationKeepsOwners() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        #expect(fixture.model.createNewInSplit())
        let source = try #require(fixture.model.pane)
        let other = try #require(fixture.model.splitPane)
        let geometry = ScrollGeometry(viewportHeight: 400, contentHeight: 1600, offset: 1200)
        for pane in [source, other] { pane.scrollBridge.publishViewport(geometry, bottomReferenceTurn: nil) }
        let resize = SplitResizeController()
        #expect(resize.begin(model: fixture.model, minimumRatio: 0.25))
        resize.update(model: fixture.model, displacement: 80, viewportHeight: 800)
        #expect(fixture.model.splitWorkspace?.topBottomRatio == 0.6)
        resize.finish(model: fixture.model, cancelled: true)
        #expect(fixture.model.splitWorkspace?.topBottomRatio == 0.5)
        #expect(fixture.model.pane === source && fixture.model.splitPane === other)
        #expect(source.scrollBridge.hasDividerLease && other.scrollBridge.hasDividerLease)
        resize.invalidate()
        #expect(!source.scrollBridge.hasDividerLease && !other.scrollBridge.hasDividerLease)
    }
    @Test("promoting the secondary physical Surface retains its actual native editor")
    func closeSourceRetainsNativeSecondaryEditor() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in try Fixtures.conversation(id: "native-survivor").insert(db) }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "native-survivor"))
        let survivor = try #require(fixture.model.splitPane)
        survivor.composer.draft.text = "native survivor draft"
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AppShellRootView(model: fixture.model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func editors(in view: UIView) -> [UITextView] {
            if let text = view as? UITextView, text.accessibilityIdentifier == "conversation-composer-input" { return [text] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        for _ in 0..<60 where editors(in: host.view).count != 2 { try await Task.sleep(for: .milliseconds(25)) }
        // Keep the original alive: allocator address reuse cannot fake identity.
        let original = try #require(editors(in: host.view).first { $0.text == "native survivor draft" })
        fixture.model.closeSplit(keeping: .bottom)
        for _ in 0..<60 where editors(in: host.view).count != 1 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(editors(in: host.view).count == 1)
        let mounted = try #require(editors(in: host.view).first)
        #expect(mounted === original)
        #expect(fixture.model.pane === survivor)
        #expect(mounted.text == "native survivor draft")
    }
    @Test("Return after deleting the opposite Split card keeps the surviving Pane as Single",
          arguments: [SplitDropSlot.top, .bottom])
    func splitReturnAfterOtherCardDeletion(originSlot: SplitDropSlot) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "delete-split-source").insert(db)
            try Fixtures.conversation(id: "delete-split-secondary").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "delete-split-source"))
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: "delete-split-source", slot: .top)))
        #expect(await fixture.model.openInSplit(id: "delete-split-secondary"))
        let source = try #require(fixture.model.pane?.session)
        let secondary = try #require(fixture.model.splitPane?.session)
        let originID = originSlot == .top ? "delete-split-source" : "delete-split-secondary"
        let deletedID = originSlot == .top ? "delete-split-secondary" : "delete-split-source"
        fixture.model.selectSplitSlot(originSlot)
        #expect(fixture.model.enterPreview())
        #expect(await fixture.model.deleteAppSpaceConversation(id: deletedID, stillSelected: { true }))
        #expect(fixture.model.pane?.conversationID != deletedID)
        #expect(fixture.model.splitPane?.conversationID != deletedID)
        #expect(await fixture.model.preparePreviewReturn(to: originID))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.splitWorkspace == nil)
        #expect(fixture.model.splitPane == nil)
        #expect(fixture.model.conversationID == originID)
        #expect(fixture.model.pane?.session === (originSlot == .top ? source : secondary))
        #expect(fixture.model.undoAppSpaceConversation(id: deletedID))
        #expect(fixture.model.splitWorkspace == nil)
        #expect(try fixture.store.conversation(id: deletedID)?.lifecycle == .visible)
    }

    @Test("deleting the Lift origin then returning to the occupied other card opens its existing owner as Single")
    func splitDeletedOriginReturnsToExistingOther() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "deleted-lift-origin").insert(db)
            try Fixtures.conversation(id: "surviving-other").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "deleted-lift-origin"))
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: "deleted-lift-origin", slot: .top)))
        #expect(await fixture.model.openInSplit(id: "surviving-other"))
        let kept = try #require(fixture.model.splitPane?.session)
        fixture.model.selectSplitSlot(.top)
        #expect(fixture.model.enterPreview())
        #expect(await fixture.model.deleteAppSpaceConversation(id: "deleted-lift-origin", stillSelected: { true }))
        #expect(await fixture.model.preparePreviewReturn(to: "surviving-other"))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.splitWorkspace == nil)
        #expect(fixture.model.conversationID == "surviving-other")
        #expect(fixture.model.pane?.session === kept)
    }

    @Test("native Composer focus selects the corresponding Split Pane without sharing drafts")
    func splitNativeFocusTransfer() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in try Fixtures.conversation(id: "focus-other").insert(db) }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "focus-other"))
        let source = try #require(fixture.model.pane?.composer)
        let other = try #require(fixture.model.splitPane?.composer)
        source.draft.text = "source focus draft"
        other.draft.text = "other focus draft"
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AppShellRootView(model: fixture.model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        func editors(in view: UIView) -> [UITextView] {
            if let text = view as? UITextView, text.accessibilityIdentifier == "conversation-composer-input" { return [text] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        for _ in 0..<60 where editors(in: host.view).count != 2 { try await Task.sleep(for: .milliseconds(25)) }
        let mounted = editors(in: host.view)
        let sourceEditor = try #require(mounted.first { $0.text == "source focus draft" })
        let otherEditor = try #require(mounted.first { $0.text == "other focus draft" })
        // Native focus callbacks are synchronous. Do not yield the main actor
        // between focus and assertions to another suite's temporary key window.
        window.makeKeyAndVisible()
        #expect(sourceEditor.becomeFirstResponder())
        #expect(fixture.model.splitWorkspace?.activeSlot == .top)
        #expect(sourceEditor.isFirstResponder && !otherEditor.isFirstResponder)
        #expect(otherEditor.becomeFirstResponder())
        #expect(fixture.model.splitWorkspace?.activeSlot == .bottom)
        #expect(otherEditor.isFirstResponder && !sourceEditor.isFirstResponder)
        #expect(source.draft.text == "source focus draft")
        #expect(other.draft.text == "other focus draft")
    }

    @Test("secondary Pane New and Recent replace that Pane while source stays live")
    func splitSecondaryNavigation() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let source = try #require(fixture.model.pane)
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "secondary-before").insert(db)
            try Fixtures.conversation(id: "secondary-after").insert(db)
        }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: source.conversationID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "secondary-before"))
        let previous = try #require(fixture.model.splitPane?.session)
        previous.composer.draft.text = "retained secondary draft"
        #expect(await fixture.model.openInSplit(id: "secondary-after"))
        #expect(fixture.model.pane === source)
        #expect(fixture.model.splitPane?.conversationID == "secondary-after")
        #expect(fixture.model.createNewInSplit())
        #expect(fixture.model.pane === source)
        #expect(fixture.model.splitPane?.conversationID != "secondary-after")
        #expect(fixture.model.splitWorkspace?.activeSlot == .bottom)
        #expect(previous.composer.draft.text == "retained secondary draft")
    }

    @Test("source Recent replaces only its Pane when Split is occupied")
    func splitSourceRecentReplacement() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "recent-kept-other").insert(db)
            try Fixtures.conversation(id: "recent-new-source").insert(db)
        }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "recent-kept-other"))
        let kept = try #require(fixture.model.splitPane)
        #expect(await fixture.model.openConversation(id: "recent-new-source"))
        #expect(fixture.model.conversationID == "recent-new-source")
        #expect(fixture.model.splitPane === kept)
        #expect(fixture.model.splitWorkspace?.sourceConversationID == "recent-new-source")
        #expect(fixture.model.splitWorkspace?.activeSlot == .top)
    }

    @Test("closing either Split Pane leaves both actual streaming Runs active and able to complete",
          arguments: [SplitDropSlot.top, .bottom])
    func splitClosePreservesBothRuns(keeping: SplitDropSlot) async throws {
        let sourceStream = Stage2StreamBox()
        let otherStream = Stage2StreamBox()
        let fixture = try makeFixture(seed: .active, scripts: [
            .holding(prefix: [.textDelta("source")], box: sourceStream),
            .holding(prefix: [.textDelta("other")], box: otherStream)
        ])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let sourceID = fixture.model.conversationID
        let sourceBridge = try #require(fixture.model.actionBridge)
        let sourceRun = try await sourceBridge.start(SendCommand(conversationID: sourceID, text: "source",
            providerInstanceID: fixture.instanceID, modelID: fixture.modelID,
            maxProviderSteps: 4, submissionID: "split-source-run"))
        await sourceStream.waitUntilReady()
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: sourceID, slot: .top)))
        #expect(fixture.model.createNewInSplit())
        let otherID = try #require(fixture.model.splitPane?.conversationID)
        let otherBridge = try #require(fixture.model.splitActionBridge)
        let otherRun = try await otherBridge.start(SendCommand(conversationID: otherID, text: "other",
            providerInstanceID: fixture.instanceID, modelID: fixture.modelID,
            maxProviderSteps: 4, submissionID: "split-other-run"))
        await otherStream.waitUntilReady()
        let survivor = try #require(keeping == .top ? fixture.model.pane : fixture.model.splitPane)
        let survivorScrollBridge = survivor.scrollBridge
        fixture.model.closeSplit(keeping: keeping)
        #expect(fixture.model.pane === survivor)
        #expect(fixture.model.pane?.scrollBridge === survivorScrollBridge)
        let promotedBridge = try #require(fixture.model.actionBridge)
        let promotedRun = try await promotedBridge.projection(survivor.conversationID)
        #expect(promotedRun?.runID == (keeping == .top ? sourceRun : otherRun))
        #expect(fixture.model.sourceSurfaceSlot == (keeping == .top ? .primary : .secondary))
        #expect(fixture.model.router.hasActiveRun(for: sourceID))
        #expect(fixture.model.router.hasActiveRun(for: otherID))
        #expect(sourceStream.cancellations == 0 && otherStream.cancellations == 0)
        sourceStream.yieldLate(.finish(.stop))
        otherStream.yieldLate(.finish(.stop))
        try await fixture.runtime.waitForCompletion(runID: sourceRun)
        try await fixture.runtime.waitForCompletion(runID: otherRun)
        #expect(try fixture.store.run(id: sourceRun)?.state == .completed)
        #expect(try fixture.store.run(id: otherRun)?.state == .completed)
        #expect(try fixture.store.conversation(id: otherID)?.lifecycle == .visible)
    }

    @Test("either occupied Split Pane can visit App Space and Return to the same two owners",
          arguments: [SplitDropSlot.top, .bottom])
    func splitAppSpaceRoundTrip(initiatingSlot: SplitDropSlot) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let sourceID = fixture.model.conversationID
        let source = try #require(fixture.model.pane?.session)
        source.composer.draft.text = "source retained"
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-return-secondary").insert(db)
        }
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(conversationID: sourceID, slot: .top))
        #expect(accepted)
        let opened = await fixture.model.openInSplit(id: "split-return-secondary")
        #expect(opened)
        let secondary = try #require(fixture.model.splitPane?.session)
        secondary.composer.draft.text = "secondary retained"
        fixture.model.selectSplitSlot(initiatingSlot)

        let entered = fixture.model.enterPreview()
        #expect(entered)
        guard entered else { return }
        let initiatingID = initiatingSlot == .top ? sourceID : "split-return-secondary"
        #expect(fixture.model.previewContent.originID == initiatingID)
        #expect(fixture.model.splitWorkspace?.sourceConversationID == sourceID)
        let prepared = await fixture.model.preparePreviewReturn(to: initiatingID)
        #expect(prepared)
        guard prepared else { return }
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.splitWorkspace?.sourceConversationID == sourceID)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == "split-return-secondary")
        #expect(fixture.model.pane?.session === source)
        #expect(fixture.model.splitPane?.session === secondary)
        #expect(source.composer.draft.text == "source retained")
        #expect(secondary.composer.draft.text == "secondary retained")
    }

    @Test("App Space selection replaces only the initiating Split Pane")
    func splitAppSpaceSelectedReplacement() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let original = try #require(fixture.model.pane?.session)
        original.composer.draft.text = "original draft"
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-kept-secondary").insert(db)
            try Fixtures.conversation(id: "split-selected-replacement").insert(db)
        }
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(
            conversationID: fixture.model.conversationID, slot: .top))
        #expect(accepted)
        let opened = await fixture.model.openInSplit(id: "split-kept-secondary")
        #expect(opened)
        let kept = try #require(fixture.model.splitPane?.session)
        kept.composer.draft.text = "kept draft"
        fixture.model.selectSplitSlot(.top)
        let entered = fixture.model.enterPreview()
        #expect(entered)
        guard entered else { return }
        let prepared = await fixture.model.preparePreviewReturn(to: "split-selected-replacement")
        #expect(prepared)
        guard prepared else { return }
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == "split-selected-replacement")
        #expect(fixture.model.splitWorkspace?.sourceConversationID == "split-selected-replacement")
        #expect(fixture.model.splitWorkspace?.sourceSlot == .top)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == "split-kept-secondary")
        #expect(fixture.model.splitPane?.session === kept)
        #expect(kept.composer.draft.text == "kept draft")
        #expect(original.composer.draft.text == "original draft")
    }

    @Test("returning to a card already open in the other Split Pane selects that owner")
    func splitAppSpaceSelectsOccupiedOtherPane() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let sourceID = fixture.model.conversationID
        let source = try #require(fixture.model.pane?.session)
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-occupied-other").insert(db)
        }
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: sourceID, slot: .top)))
        #expect(await fixture.model.openInSplit(id: "split-occupied-other"))
        let other = try #require(fixture.model.splitPane?.session)
        fixture.model.selectSplitSlot(.top)
        #expect(fixture.model.enterPreview())
        #expect(await fixture.model.preparePreviewReturn(to: "split-occupied-other"))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.splitWorkspace?.activeSlot == .bottom)
        #expect(fixture.model.pane?.session === source)
        #expect(fixture.model.splitPane?.session === other)
        #expect(fixture.model.splitWorkspace?.sourceConversationID == sourceID)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == "split-occupied-other")
    }

    @Test("source Pane New replaces only that Pane and keeps the other live owner")
    func splitSourceNewPreservesOtherPane() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let oldSourceID = fixture.model.conversationID
        let oldSource = try #require(fixture.model.pane?.session)
        oldSource.composer.draft.text = "old source draft"
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-new-kept").insert(db)
        }
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(conversationID: oldSourceID, slot: .top))
        #expect(accepted)
        let opened = await fixture.model.openInSplit(id: "split-new-kept")
        #expect(opened)
        let kept = try #require(fixture.model.splitPane?.session)
        fixture.model.newConversation()
        #expect(fixture.model.conversationID != oldSourceID)
        #expect(fixture.model.splitWorkspace?.sourceConversationID == fixture.model.conversationID)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == "split-new-kept")
        #expect(fixture.model.splitPane?.session === kept)
        #expect(oldSource.composer.draft.text == "old source draft")
    }

    @Test("Recent opening the other Split Pane selects its existing owner")
    func splitRecentSelectsExistingOwner() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let sourceID = fixture.model.conversationID
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-recent-other").insert(db)
        }
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(conversationID: sourceID, slot: .top))
        #expect(accepted)
        let opened = await fixture.model.openInSplit(id: "split-recent-other")
        #expect(opened)
        let other = try #require(fixture.model.splitPane)
        fixture.model.selectSplitSlot(.top)
        let selected = await fixture.model.openConversation(id: "split-recent-other")
        #expect(selected)
        #expect(fixture.model.conversationID == sourceID)
        #expect(fixture.model.splitPane === other)
        #expect(fixture.model.splitWorkspace?.activeSlot == .bottom)
    }

    @Test("Split keeps two independent Pane owners; closing it preserves the secondary Conversation")
    func splitOwnersAndClose() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let sourceID = fixture.model.conversationID
        let source = try #require(fixture.model.pane?.session)
        source.composer.draft.text = "source draft"
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "split-secondary").insert(db)
        }
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(conversationID: sourceID, slot: .bottom))
        #expect(accepted)
        #expect(fixture.model.splitWorkspace?.sourceSlot == .bottom)
        #expect(fixture.model.splitWorkspace?.emptySlot == .top)
        let duplicateOpened = await fixture.model.openInSplit(id: sourceID)
        #expect(!duplicateOpened)
        let opened = await fixture.model.openInSplit(id: "split-secondary")
        #expect(opened)
        let secondary = try #require(fixture.model.splitPane?.session)
        #expect(secondary !== source)
        secondary.composer.draft.text = "secondary draft"
        #expect(fixture.model.pane?.session === source)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == "split-secondary")
        fixture.model.closeSplit()
        #expect(fixture.model.splitWorkspace == nil)
        #expect(fixture.model.splitPane == nil)
        #expect(fixture.model.pane?.session === source)
        #expect(source.composer.draft.text == "source draft")
        #expect(try fixture.store.conversation(id: "split-secondary")?.lifecycle == .visible)
        #expect(await fixture.model.openConversation(id: "split-secondary"))
        #expect(fixture.model.pane?.session === secondary)
        #expect(secondary.composer.draft.text == "secondary draft")
    }

    @Test("a failed Split selection leaves the source and empty Picker owner intact")
    func failedSplitSelection() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let source = try #require(fixture.model.pane?.session)
        let accepted = fixture.model.commitSplitDrop(SplitDropIntent(
            conversationID: fixture.model.conversationID, slot: .top))
        #expect(accepted)
        let opened = await fixture.model.openInSplit(id: "missing-split-target")
        #expect(!opened)
        #expect(fixture.model.pane?.session === source)
        #expect(fixture.model.splitPane == nil)
        #expect(fixture.model.splitWorkspace?.secondaryConversationID == nil)
        #expect(fixture.model.splitOpenError != nil)
    }

    @Test("finalized Card Delete releases the warm origin and still opens another card")
    func finalizedCardDeleteReleasesOriginSession() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "delete-origin").insert(db)
            try Fixtures.conversation(id: "delete-next").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "delete-origin"))
        weak var original: ConversationSession?
        do {
            original = try #require(fixture.model.pane?.session)
            #expect(fixture.model.enterPreview())
        }
        #expect(original != nil)
        _ = try fixture.store.beginCardDeletion(conversationID: "delete-origin",
            at: Date().addingTimeInterval(-3600))
        let deletion = try #require(fixture.model.cardDeletion)
        deletion.recoverPending()
        #expect(deletion.needsRecoveryDecision(conversationID: "delete-origin"))
        #expect(fixture.model.confirmRecoveredAppSpaceConversationDeletion(id: "delete-origin"))
        #expect(try fixture.store.conversationLifecycle(id: "delete-origin") == .finalizedDeletion)
        #expect(original == nil)
        #expect(fixture.model.previewContent.session == nil)
        #expect(await fixture.model.preparePreviewReturn(to: "delete-next"))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == "delete-next")
    }

    @Test("selected Return preserves the outgoing actual Run and warm reading state")
    func selectedCardDoesNotStopHiddenStreaming() async throws {
        let box = Stage2StreamBox()
        let fixture = try makeFixture(seed: .active, scripts: [.holding(prefix: [.textDelta("before")], box: box)])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = fixture.model.conversationID
        try fixture.store.database.write { db in try Fixtures.conversation(id: "selected-stream-target").insert(db) }
        let bridge = try #require(fixture.model.actionBridge)
        let runID = try await bridge.start(SendCommand(conversationID: id, text: "selected streaming",
            providerInstanceID: fixture.instanceID, modelID: fixture.modelID, maxProviderSteps: 4,
            submissionID: "selected-streaming"))
        await box.waitUntilReady()
        for _ in 0..<100 {
            if try ConversationTimelineLoader.load(conversationID: id, from: fixture.store).turns
                .flatMap(\.items).contains(.assistantText("before")) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try #require(fixture.model.pane?.session)
        let anchor = TurnAnchor(runID: runID, relativeViewportOffset: 0.2)
        original.readingPosition.setReadingAnchorForUITest(anchor)
        weak var oldPane = fixture.model.pane
        #expect(fixture.model.enterPreview())
        let requests = fixture.model.router.historyPreparation.requested
        let browse = AppSpaceBrowseController(reader: { try fixture.store.conversationBrowseWindow(id: $0) })
        browse.present(originID: id)
        #expect(browse.begin())
        #expect(browse.drag(displacement: 200, travel: 300))
        let move = try #require(browse.end(velocity: 0, travel: 300))
        #expect(browse.complete(move, finished: true))
        #expect(browse.currentSummary?.id == "selected-stream-target")
        #expect(fixture.model.conversationID == id && oldPane == nil)
        #expect(fixture.model.previewContent.session === original)
        #expect(fixture.model.router.historyPreparation.requested == requests)
        #expect(await fixture.model.preparePreviewReturn(to: browse.selectedConversationID))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == "selected-stream-target")
        #expect(fixture.model.router.hasActiveRun(for: id) && box.cancellations == 0)
        box.yieldLate(.textDelta(" after"))
        box.yieldLate(.finish(.stop))
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(try fixture.store.run(id: runID)?.state == .completed)
        // Stage2StreamBox counts normal AsyncThrowingStream termination too.
        // The live assertions above prove navigation did not tear down the stream.
        #expect(box.cancellations == 1)
        #expect(await fixture.model.openConversation(id: id))
        let restored = try #require(fixture.model.pane)
        #expect(restored.session === original)
        #expect(restored.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText("before after")))
        if case .reading(let value, _) = restored.readingPosition.mode { #expect(value == anchor) }
        else { #expect(false, "Selected Return lost the outgoing reading anchor") }
    }

    @Test("real native snap interruption cannot commit its late neighbor", arguments: [false, true])
    func nativeSnapInterruption(returnToFull: Bool) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<2 {
                var row = Fixtures.conversation(id: "snap-interrupt-\(index)", title: "Snap interrupt \(index)")
                row.userActiveAt = Fixtures.epoch.addingTimeInterval(Double(index))
                try row.insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "snap-interrupt-1"))
        let original = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        let lift = SurfaceLiftController()
        let host = UIHostingController(rootView: WorkspaceSurfaceView(model: fixture.model, liftController: lift) {
            NewConversationView(model: fixture.model)
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        func findCard(_ view: UIView) -> SurfaceClipView? {
            if let card = view as? SurfaceClipView, card.accessibilityIdentifier == "workspace-current-card" { return card }
            return view.subviews.lazy.compactMap(findCard).first
        }
        for _ in 0..<40 where findCard(host.view)?.accessibilityIdentifier != "workspace-current-card" {
            try await Task.sleep(for: .milliseconds(25))
        }
        let card = try #require(findCard(host.view))
        let native = try #require(card.gestureRecognizers?.compactMap { $0.delegate as? AppSpaceBrowseInteraction }.first)
        #expect(fixture.model.previewContent.summaries.isEmpty, "Workspace must retain only one summary window")
        #expect(native.controller.summaries.count <= 5)
        let action = try #require(card.accessibilityCustomActions?.first { $0.name == "上一会话" })
        let handler = try #require(action.actionHandler)
        #expect(handler(action))
        let animator = try #require(native.animatorForTesting)
        animator.pauseAnimation()
        animator.fractionComplete = 0.4
        CATransaction.flush()
        let pending = try #require(native.controller.state.pendingSettlement)
        if returnToFull {
            #expect(card.accessibilityActivate())
        } else {
            let container = try #require(card.superview)
            container.frame.size.width += 80
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }
        #expect(native.animatorForTesting == nil)
        #expect(!native.controller.complete(pending, finished: true))
        #expect(native.controller.state.selected == .conversation("snap-interrupt-1"))
        if returnToFull {
            for _ in 0..<80 where lift.state.phase != .full || fixture.model.previewContent.isPresented {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(lift.state.phase == .full)
            #expect(!fixture.model.previewContent.isPresented)
        } else {
            try await Task.sleep(for: .milliseconds(800))
        }
        #expect(fixture.model.conversationID == "snap-interrupt-1")
        #expect(card.alpha == 1)
        if returnToFull {
            #expect(fixture.model.pane?.session === original)
            #expect(card.transform == .identity)
        } else {
            #expect(fixture.model.pane == nil && fixture.model.previewContent.session === original)
            #expect(native.controller.state.selected == .conversation("snap-interrupt-1"))
        }
    }

    @Test("Preview retains durable reconstruction eligibility under warm-cache pressure")
    func previewDoesNotDisableExistingWarmEviction() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<15 { try Fixtures.conversation(id: "preview-warm-\(index)").insert(db) }
        }
        #expect(await fixture.model.openConversation(id: "preview-warm-0"))
        weak var evictable = fixture.model.pane?.session
        for index in 1..<15 {
            #expect(fixture.model.enterPreview())
            #expect(await fixture.model.preparePreviewReturn(to: "preview-warm-\(index)"))
            #expect(fixture.model.commitPreviewReturn())
            #expect(fixture.model.conversationID == "preview-warm-\(index)")
        }
        #expect(evictable == nil, "Preview must not permanently pin a reconstructible Session")
    }

    @Test("real hosted Card accessibility actions browse without preparing Full")
    func nativeCardAccessibilityBrowse() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<6 {
                var row = Fixtures.conversation(id: "native-browse-\(index)", title: "Native browse \(index)")
                row.userActiveAt = Fixtures.epoch.addingTimeInterval(Double(index))
                try row.insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "native-browse-5"))
        let session = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        let requests = fixture.model.router.historyPreparation.requested
        let host = UIHostingController(rootView: WorkspaceSurfaceView(model: fixture.model) {
            NewConversationView(model: fixture.model)
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        func findCard(_ view: UIView) -> SurfaceClipView? {
            if let card = view as? SurfaceClipView, card.accessibilityIdentifier == "workspace-current-card" { return card }
            return view.subviews.lazy.compactMap(findCard).first
        }
        for _ in 0..<40 where findCard(host.view)?.accessibilityIdentifier != "workspace-current-card" {
            try await Task.sleep(for: .milliseconds(25))
        }
        let card = try #require(findCard(host.view))
        // S5-06 adds the distinct New after the latest history. Keep the existing
        // native older/newer controls and exercise the new boundary as well.
        #expect(card.accessibilityCustomActions?.contains { $0.name == "下一会话" } == true)
        #expect(card.accessibilityCustomActions?.contains { $0.name == "删除会话" } == true)
        let previous = try #require(card.accessibilityCustomActions?.first { $0.name == "上一会话" })
        let previousHandler = try #require(previous.actionHandler)
        #expect(previousHandler(previous))
        for _ in 0..<40 where card.accessibilityLabel?.contains("Native browse 4") != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(card.accessibilityLabel?.contains("Native browse 4") == true)
        #expect(fixture.model.conversationID == "native-browse-5" && fixture.model.pane == nil)
        #expect(fixture.model.previewContent.session === session && fixture.model.previewContent.prepared == nil)
        #expect(fixture.model.router.historyPreparation.requested == requests)
        let next = try #require(card.accessibilityCustomActions?.first { $0.name == "下一会话" })
        let nextHandler = try #require(next.actionHandler)
        #expect(nextHandler(next))
        for _ in 0..<40 where card.accessibilityLabel?.contains("Native browse 5") != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(card.accessibilityLabel?.contains("Native browse 5") == true)
        #expect(fixture.model.router.historyPreparation.requested == requests)
        let toNew = try #require(card.accessibilityCustomActions?.first { $0.name == "下一会话" })
        let toNewHandler = try #require(toNew.actionHandler)
        #expect(toNewHandler(toNew))
        for _ in 0..<40 where card.accessibilityLabel?.contains("创建新对话") != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(card.accessibilityLabel?.contains("创建新对话") == true)
        #expect(card.accessibilityCustomActions?.contains { $0.name == "会话菜单" } == false)
        #expect(card.accessibilityCustomActions?.contains { $0.name == "删除会话" } == false)
        #expect(card.accessibilityCustomActions?.contains { $0.name == "创建新对话" } == true)
        let fromNew = try #require(card.accessibilityCustomActions?.first { $0.name == "上一会话" })
        let fromNewHandler = try #require(fromNew.actionHandler)
        #expect(fromNewHandler(fromNew))
        for _ in 0..<40 where card.accessibilityLabel?.contains("Native browse 5") != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(card.accessibilityLabel?.contains("Native browse 5") == true)
        #expect(fixture.model.previewContent.session === session && fixture.model.previewContent.prepared == nil)
        #expect(fixture.model.router.historyPreparation.requested == requests)
    }

    @Test("selected Card prepares a different history without replacing the original warm owner")
    func selectedPreviewHandoffPreservesOriginal() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "browse-origin").insert(db)
            try Fixtures.conversation(id: "browse-target").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "browse-origin"))
        let original = try #require(fixture.model.pane?.session)
        original.composer.draft.text = "未发送的原会话草稿"
        #expect(fixture.model.enterPreview())
        let reads = fixture.model.router.historyPreparation.requested
        #expect(await fixture.model.preparePreviewReturn(to: "browse-target"))
        #expect(fixture.model.conversationID == "browse-origin" && fixture.model.pane == nil)
        #expect(fixture.model.previewContent.session === original)
        weak var cancelled = fixture.model.previewContent.prepared?.pane
        #expect(cancelled?.conversationID == "browse-target")
        fixture.model.cancelPreviewReturn()
        #expect(cancelled == nil)
        #expect(fixture.model.previewContent.session === original)
        #expect(await fixture.model.preparePreviewReturn(to: "browse-target"))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == "browse-target")
        #expect(fixture.model.pane?.conversationID == "browse-target")
        #expect(fixture.model.router.historyPreparation.requested == reads + 2)
        #expect(try fixture.store.conversation(id: "browse-origin")?.userActiveAt == Fixtures.epoch)
        #expect(try fixture.store.conversation(id: "browse-target")?.userActiveAt == Fixtures.epoch)
        #expect(await fixture.model.openConversation(id: "browse-origin"))
        #expect(fixture.model.pane?.session === original)
        #expect(original.composer.draft.text == "未发送的原会话草稿")
    }

    @Test("selected Return cannot invent an absent or pending-deletion history")
    func selectedPreviewUnavailableTarget() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "browse-visible").insert(db)
            try Fixtures.conversation(id: "browse-deleted", lifecycle: .pendingDeletion).insert(db)
        }
        #expect(await fixture.model.openConversation(id: "browse-visible"))
        let original = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        for id in ["browse-deleted", "browse-missing"] {
            #expect(!(await fixture.model.preparePreviewReturn(to: id)))
            #expect(!fixture.model.commitPreviewReturn())
            #expect(fixture.model.previewContent.session === original)
            #expect(fixture.model.conversationID == "browse-visible" && fixture.model.pane == nil)
        }
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.pane?.session === original)
    }

    @Test("releasing an idle shell releases its registered route and native display owner")
    func idleShellReleasesRoute() throws {
        weak var route: RunEventRouter?
        weak var display: ConversationPaneController?
        do {
            let fixture = try makeFixture(seed: .active)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
            route = fixture.model.router
            display = fixture.model.pane
            #expect(route != nil && display != nil)
        }
        #expect(route == nil && display == nil)
    }

    @Test("cancelling Return stops obsolete SQL work before a new Return completes")
    func previewCancellationStopsHistoryWork() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "cancel-work", messageID: "cancel-work-user", runID: "cancel-work-run", runState: .completed))
        #expect(await fixture.model.openConversation(id: "cancel-work"))
        #expect(fixture.model.enterPreview())
        for _ in 0..<3 {
            let gate = PreviewReadGate()
            let trace = S504SQLTrace()
            defer {
                gate.release()
                try? fixture.store.database.read { db in db.trace(nil) }
                #expect(!gate.timedOut, "cancel gate expired before explicit release")
            }
            try fixture.store.database.read { db in
                db.trace { event in
                    if case .statement(let statement) = event {
                        trace.record(statement.sql)
                        if statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
                    }
                }
            }
            let oldReturn = Task { await fixture.model.preparePreviewReturn() }
            for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
            _ = try #require(gate.hasBlocked, "cancel test did not start its history read")
            oldReturn.cancel()
            fixture.model.cancelPreviewReturn()
            gate.release()
            #expect(!(await oldReturn.value))
            try fixture.store.database.read { db in db.trace(nil) }
            #expect(trace.selectCount <= 2, "cancelled work kept executing \(trace.selectCount) history SELECTs")
            #expect(fixture.model.pane == nil && fixture.model.previewContent.isPresented)
        }
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.commitPreviewReturn())
    }

    @Test("durable deltas and terminal events during history cannot starve Preview Return", arguments: [false, true])
    func previewDeltasDuringHistoryRead(endsDuringRead: Bool) async throws {
        let path = try Fixtures.scratchPath(name: "preview-continuous.sqlite")
        let store = PersistenceStore(database: try ZenDatabase.open(at: path.path))
        let writer = PersistenceStore(database: try ZenDatabase.open(at: path.path))
        let fixture = try makeFixture(seed: .active, store: store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = "read-with-deltas"
        let runID = "read-with-deltas-run"
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(conversationID: id,
            messageID: "read-user", runID: runID, runState: .streaming))
        _ = try store.ensureAssistantResponse(forRunID: runID, messageID: "read-assistant")
        try store.createPart(Fixtures.streamingPart(id: "read-part", messageID: "read-assistant", text: "before"))
        #expect(await fixture.model.openConversation(id: id))
        fixture.model.router.registerRecoveredRun(runID: runID, conversationID: id)
        await fixture.model.router.handle(.messagePartStarted(runID: runID,
            messageID: "read-assistant", partID: "read-part", kind: .text))
        let session = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        let gate = HistoryReadRounds()
        defer {
            gate.release()
            try? store.database.read { db in db.trace(nil) }
            #expect(!gate.timedOut, "delta gate expired before explicit release")
        }
        try store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("from \"message\"") { gate.blockNext() }
            }
        }
        var result: Bool?
        let operation = Task { result = await fixture.model.preparePreviewReturn() }
        var expected = "before"
        for round in 1...3 {
            for _ in 0..<200 where gate.entered < round && result == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            if result != nil { break }
            _ = try #require(gate.entered >= round, "history read did not reach its gate")
            let delta = " 你好\(round)👋"
            try writer.appendText(toPart: "read-part", delta: delta)
            expected += delta
            await fixture.model.router.handle(.messagePartDelta(runID: runID,
                partID: "read-part", delta: delta, endUTF8Offset: expected.utf8.count))
            if endsDuringRead {
                try writer.finishPart(id: "read-part", state: .completed)
                try writer.transitionRun(id: runID, expectedState: .streaming, to: .completed, endReason: .completed)
                await fixture.model.router.handle(.messagePartCompleted(runID: runID, partID: "read-part", state: .completed))
                await fixture.model.router.handle(.runEnded(runID: runID, state: .completed, endReason: .completed))
            }
            gate.release()
        }
        await operation.value
        #expect(result == true)
        #expect(fixture.model.commitPreviewReturn())
        let pane = try #require(fixture.model.pane)
        #expect(pane.session === session)
        #expect(pane.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText(expected)))
        if !endsDuringRead {
            try writer.finishPart(id: "read-part", state: .completed)
            await fixture.model.router.handle(.messagePartCompleted(runID: runID, partID: "read-part", state: .completed))
        }
        #expect(pane.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText(expected)))
        #expect(pane.liveStore.droppedUnlocatableDeltas == 0)
        #expect(!pane.liveStore.needsTimelineReload)
        if endsDuringRead { #expect(pane.liveStore.state.activeParts.isEmpty) }
    }

    @Test("queued Open keeps the outgoing Pane and only the latest navigation starts a read")
    func queuedNavigationHasOneHistoryWorker() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for id in ["queued-a", "queued-b", "queued-c"] { try Fixtures.conversation(id: id).insert(db) }
        }
        let outgoing = try #require(fixture.model.pane)
        let owner = fixture.model.router.historyPreparation
        let started = owner.started
        let finished = owner.finished
        let requested = owner.requested
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut, "navigation gate expired before explicit release")
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let first = Task { await fixture.model.openConversation(id: "queued-a") }
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(gate.hasBlocked)
        let second = Task { await fixture.model.openConversation(id: "queued-b") }
        for _ in 0..<200 where owner.requested < requested + 2 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(owner.requested == requested + 2)
        let third = Task { await fixture.model.openConversation(id: "queued-c") }
        for _ in 0..<200 where owner.requested < requested + 3 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(owner.requested == requested + 3)
        #expect(fixture.model.pane === outgoing)
        #expect(owner.inFlight == 1 && owner.started == started + 1)
        gate.release()
        #expect(!(await first.value))
        #expect(!(await second.value))
        #expect(await third.value)
        #expect(fixture.model.conversationID == "queued-c")
        #expect(owner.started == started + 2 && owner.finished == finished + 2 && owner.inFlight == 0)
    }
    @Test("an outgoing Run acceptance cannot cancel a user's Open", arguments: [false, true])
    func outgoingRunCannotCancelOpen(acceptanceFirst: Bool) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let outgoing = try #require(fixture.model.pane)
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: outgoing.conversationID, messageID: "outgoing-user", runID: "outgoing-run"))
        try fixture.store.database.write { db in try Fixtures.conversation(id: "open-target").insert(db) }
        let owner = fixture.model.router.historyPreparation
        let requested = owner.requested
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut, "acceptance gate expired before explicit release")
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let firstNavigation = acceptanceFirst ? nil : Task { await fixture.model.openConversation(id: "open-target") }
        let firstAcceptance = acceptanceFirst ? Task { await fixture.model.router.handle(.runAccepted(
            runID: "outgoing-run", conversationID: outgoing.conversationID)) } : nil
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(gate.hasBlocked)
        let navigation = firstNavigation ?? Task { await fixture.model.openConversation(id: "open-target") }
        let acceptance = firstAcceptance ?? Task { await fixture.model.router.handle(.runAccepted(
            runID: "outgoing-run", conversationID: outgoing.conversationID)) }
        for _ in 0..<200 where owner.requested < requested + 2 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(owner.requested == requested + 2)
        #expect(fixture.model.pane === outgoing)
        #expect(owner.inFlight == 1)
        gate.release()
        #expect(await navigation.value)
        await acceptance.value
        #expect(fixture.model.conversationID == "open-target")
        #expect(fixture.model.router.hasActiveRun(for: outgoing.conversationID))
        #expect(fixture.model.router.recoveryMessage(for: outgoing.conversationID) == nil)
        #expect(owner.inFlight == 0)
    }

    @Test("native Composer remount preserves a pre-acceptance Send and its late error")
    func previewPendingSendSurvivesNativeRemount() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let original = try #require(fixture.model.actionBridge)
        let gate = PreviewSubmissionGate()
        defer { Task { await gate.release() } }
        var bridge = original
        bridge.start = { command in
            let ordinal = await gate.enter(command)
            throw ordinal == 1 ? ComposerSendFailure.keychainUnavailable : ComposerSendFailure.configurationUnavailable
        }
        let runtime = fixture.runtime
        let pane = try #require(fixture.model.pane)
        pane.composer.draft.text = "pending native Send"
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(ConversationPaneView(pane: pane, runtime: runtime,
            actionBridge: bridge, maxProviderSteps: AppShellModel.maxProviderSteps)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func native<T: UIView>(_ type: T.Type, id: String, in view: UIView) -> T? {
            if let found = view as? T, found.accessibilityIdentifier == id { return found }
            return view.subviews.lazy.compactMap { native(type, id: id, in: $0) }.first
        }
        for _ in 0..<100 {
            if native(UITextView.self, id: "conversation-composer-input", in: host.view)?.text == "pending native Send",
               native(UIButton.self, id: "conversation-composer-send", in: host.view)?.isEnabled == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let send = try #require(native(UIButton.self, id: "conversation-composer-send", in: host.view))
        #expect(send.isEnabled)
        let firstCoordinator = try #require(pane.composer.nativeSendCoordinatorForUITest)
        let firstAction = Task { await firstCoordinator.handlePrimaryAction() }
        for _ in 0..<100 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialCount = await gate.count
        print("PREVIEW_SEND_CONTROL count=\(initialCount) error=\(firstCoordinator.sendErrorMessage ?? "none") submission=\(firstCoordinator.submission)")
        try #require(initialCount == 1)
        let pendingDraft = pane.composer.draft
        pane.composer.draft = ComposerDraftState(text: "", selection: ComposerSelection(range: 0..<0),
            references: [], attachments: [], presentationState: .resting)
        #expect(!pane.session.canReconstruct(configuration: pane.composer.configuration))
        pane.composer.draft = pendingDraft
        weak var oldEditor = native(UITextView.self, id: "conversation-composer-input", in: host.view)
        #expect(fixture.model.enterPreview())
        host.rootView = AnyView(ConversationPreviewView(summary: fixture.model.previewContent.currentSummary))
        for _ in 0..<100 where oldEditor != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(oldEditor == nil)
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.commitPreviewReturn())
        let restored = try #require(fixture.model.pane)
        #expect(restored.session === pane.session)
        host.rootView = AnyView(ConversationPaneView(pane: restored, runtime: runtime,
            actionBridge: bridge, maxProviderSteps: AppShellModel.maxProviderSteps))
        for _ in 0..<100 where native(UITextView.self, id: "conversation-composer-input", in: host.view) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let remountedSend = try #require(native(UIButton.self, id: "conversation-composer-send", in: host.view))
        #expect(!remountedSend.isEnabled)
        // Even a stale native action must resolve through the same pending transaction.
        let currentCoordinator = try #require(restored.composer.nativeSendCoordinatorForUITest)
        #expect(currentCoordinator === firstCoordinator)
        _ = await currentCoordinator.handlePrimaryAction()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.count == 1)
        await gate.release()
        _ = await firstAction.value
        for _ in 0..<100 {
            if native(UILabel.self, id: "composer-send-error", in: host.view)?.text == "Keychain 不可用" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(native(UILabel.self, id: "composer-send-error", in: host.view)?.text == "Keychain 不可用")
        #expect(restored.composer.draft.text == "pending native Send")
    }

    @Test("a first durable commit while Card acquires current title and Run status in a bounded refresh")
    func newPreviewRefreshAcquiresCommittedCurrent() async throws {
        let box = Stage2StreamBox()
        let fixture = try makeFixture(seed: .active, scripts: [.holding(prefix: [.textDelta("first reply")], box: box)])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<3 { try Fixtures.conversation(id: "new-card-predecessor-\(index)").insert(db) }
        }
        let id = fixture.model.conversationID
        let bridge = try #require(fixture.model.actionBridge)
        let gate = PreviewCommitGate()
        defer { Task { await gate.release() } }
        let start = Task {
            await gate.hold()
            return try await bridge.start(SendCommand(conversationID: id, text: "First Card commit",
                providerInstanceID: fixture.instanceID, modelID: fixture.modelID, maxProviderSteps: 4,
                submissionID: "new-card-first-commit"))
        }
        for _ in 0..<100 {
            if await gate.hasEntered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.hasEntered)
        #expect(fixture.model.enterPreview())
        #expect(fixture.model.previewContent.currentSummary == nil)
        await gate.release()
        let runID = try await start.value
        await box.waitUntilReady()
        let trace = S504SQLTrace()
        try fixture.store.database.read { db in
            db.trace { event in if case .statement(let statement) = event { trace.record(statement.sql) } }
        }
        fixture.model.refreshPreview()
        try fixture.store.database.read { db in db.trace(nil) }
        #expect(trace.summaryQueryCount == 1)
        #expect(fixture.model.previewContent.summaries.count <= 4)
        #expect(Set(fixture.model.previewContent.summaries.map(\.id)).count == fixture.model.previewContent.summaries.count)
        #expect(fixture.model.previewContent.currentSummary?.id == id)
        #expect(fixture.model.previewContent.currentSummary?.title == "First Card commit")
        #expect(fixture.model.previewContent.currentSummary?.runProjection?.runID == runID)
        #expect(fixture.model.previewContent.accessibilityLabel.contains("生成中"))
        box.yieldLate(.finish(.stop))
        try await fixture.runtime.waitForCompletion(runID: runID)
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.currentSummary?.runProjection?.state == .completed)
    }

    @Test("opening the current Preview installs exactly one registered Full owner", arguments: [false, true])
    func openingCurrentPreview(prewarm: Bool) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in try Fixtures.conversation(id: "current-preview").insert(db) }
        #expect(await fixture.model.openConversation(id: "current-preview"))
        #expect(fixture.model.enterPreview())
        if prewarm { #expect(await fixture.model.preparePreviewReturn()) }
        #expect(await fixture.model.openConversation(id: "current-preview"))
        let full = try #require(fixture.model.pane)
        #expect(!fixture.model.previewContent.isPresented)
        #expect(!fixture.model.router.registerPane(full))
    }

    @Test("a new page's readiness does not inherit a corrupt predecessor's status")
    func newPreviewReadinessIsScoped() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "corrupt-predecessor").insert(db)
            try Fixtures.message(id: "corrupt-preview-message", conversationID: "corrupt-predecessor").insert(db)
            try Fixtures.textPart(id: "corrupt-preview-part", messageID: "corrupt-preview-message").insert(db)
            try db.execute(sql: "UPDATE messagePart SET payload = ? WHERE id = ?", arguments: ["{bad", "corrupt-preview-part"])
        }
        #expect(fixture.model.enterPreview())
        #expect(fixture.model.previewContent.summaries.first?.contentUnavailable == true)
        #expect(fixture.model.previewContent.status == .ready)
    }

    @Test("the production Current Card accessibility container announces its Run status")
    func previewCardAnnouncesRunStatus() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "card-status", title: "Failed conversation").insert(db)
            try Fixtures.run(id: "card-status-run", conversationID: "card-status", state: .failed,
                endReason: .providerInterrupted).insert(db)
        }
        #expect(await fixture.model.openConversation(id: "card-status"))
        let driver = SurfaceLiftController()
        let host = UIHostingController(rootView: WorkspaceSurfaceView(model: fixture.model, liftController: driver) {
            NewConversationView(model: fixture.model)
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where !driver.canArm(SurfaceLiftEligibility()) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end(animated: false)?.destination == .card)
        func card(in view: UIView) -> SurfaceClipView? {
            if let card = view as? SurfaceClipView, card.accessibilityIdentifier == "workspace-current-card" { return card }
            return view.subviews.lazy.compactMap { card(in: $0) }.first
        }
        let current = try #require(card(in: host.view))
        #expect(current.accessibilityLabel?.contains("Failed conversation") == true)
        #expect(current.accessibilityLabel?.contains("运行失败") == true)
    }

    @Test("an invalidated in-flight read cannot replace navigation or a newer Return", arguments: [false, true])
    func previewInFlightCancellation(navigate: Bool) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "inflight-a").insert(db)
            try Fixtures.conversation(id: "inflight-b").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "inflight-a"))
        let session = try #require(fixture.model.pane?.session)
        session.composer.draft.text = "pending load draft"
        #expect(fixture.model.enterPreview())
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { db in db.trace(nil) }
            #expect(!gate.timedOut, "inflight gate expired before explicit release")
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let oldReturn = Task { await fixture.model.preparePreviewReturn() }
        for _ in 0..<100 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.hasBlocked)
        fixture.model.cancelPreviewReturn()
        let newerReturn: Task<Bool, Never>? = navigate ? nil : Task { await fixture.model.preparePreviewReturn() }
        gate.release()
        if navigate { #expect(await fixture.model.openConversation(id: "inflight-b")) }
        #expect(!(await oldReturn.value))
        if let newerReturn {
            #expect(await newerReturn.value)
            #expect(fixture.model.commitPreviewReturn())
            #expect(fixture.model.pane?.session === session)
        } else {
            #expect(fixture.model.conversationID == "inflight-b")
            #expect(!fixture.model.commitPreviewReturn())
        }
        #expect(!fixture.model.previewContent.isPreparing)
    }

    @Test("production handoff remains Preview before the late segment and cancellation discards prepared content")
    func liftPreviewLateHandoffAndCancellation() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let driver = SurfaceLiftController()
        let host = ConversationSurfaceViewController(content:
            NewConversationView(model: fixture.model).environment(\.surfaceLiftController, driver))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        driver.bind(host)
        driver.configurePreview(enter: { fixture.model.enterPreview() },
            prepare: { await fixture.model.preparePreviewReturn() },
            commit: { fixture.model.commitPreviewReturn() }, cancel: { fixture.model.cancelPreviewReturn() },
            isPresented: { fixture.model.previewContent.isPresented }, label: { "Preview handoff" })
        #expect(driver.arm(SurfaceLiftEligibility()))
        #expect(driver.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        #expect(driver.end(animated: false)?.destination == .card)
        #expect(fixture.model.pane == nil)
        #expect(driver.returnToFull())
        for _ in 0..<100 where host.liftAnimatorForTesting == nil { try await Task.sleep(for: .milliseconds(5)) }
        let animator = try #require(host.liftAnimatorForTesting)
        animator.pauseAnimation()
        animator.fractionComplete = 0.2
        #expect(driver.state.phase == .settling && fixture.model.pane == nil)
        weak var prepared = fixture.model.previewContent.prepared?.pane
        #expect(prepared != nil)
        let settlement = driver.state.pendingSettlement
        #expect(driver.returnToFull())
        #expect(driver.state.pendingSettlement == settlement)
        driver.invalidate()
        #expect(driver.state.phase == .card && fixture.model.previewContent.isPresented)
        #expect(prepared == nil && fixture.model.pane == nil)
        #expect(driver.returnToFull(animated: false))
        for _ in 0..<100 where driver.state.phase != .full { try await Task.sleep(for: .milliseconds(5)) }
        #expect(driver.state.phase == .full && fixture.model.pane != nil)
        #expect(!fixture.model.previewContent.isPresented)
    }

    @Test("a prepared Preview Return releases its hidden Pane on cancellation and navigation")
    func previewPreparationCancellationAndNavigation() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "preview-cancel-a").insert(db)
            try Fixtures.conversation(id: "preview-cancel-b").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "preview-cancel-a"))
        let session = try #require(fixture.model.pane?.session)
        session.composer.draft.text = "cancel-safe draft"
        #expect(fixture.model.enterPreview())
        #expect(await fixture.model.preparePreviewReturn())
        weak var prepared = fixture.model.previewContent.prepared?.pane
        #expect(prepared != nil && fixture.model.pane == nil)
        fixture.model.cancelPreviewReturn()
        #expect(prepared == nil)
        #expect(fixture.model.previewContent.isPresented)
        #expect(await fixture.model.preparePreviewReturn())
        prepared = fixture.model.previewContent.prepared?.pane
        #expect(await fixture.model.openConversation(id: "preview-cancel-b"))
        #expect(prepared == nil && !fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == "preview-cancel-b")
        #expect(await fixture.model.openConversation(id: "preview-cancel-a"))
        #expect(fixture.model.pane?.session === session)
        #expect(session.composer.draft.text == "cancel-safe draft")
    }

    @Test("a successful summary refresh clears only its refresh error")
    func previewRefreshRecovers() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("refresh history", at: Fixtures.epoch, in: fixture)
        #expect(fixture.model.enterPreview())
        let before = fixture.model.previewContent.summaries
        let id = fixture.model.conversationID
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE message RENAME TO failed_refresh_message") }
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.errorMessage != nil)
        #expect(fixture.model.previewContent.summaries == before)
        try fixture.store.database.write { db in
            try db.execute(sql: "ALTER TABLE failed_refresh_message RENAME TO message")
            try db.execute(sql: "UPDATE conversation SET title = ? WHERE id = ?",
                arguments: ["recovered preview", id])
        }
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.currentSummary?.title == "recovered preview")
        #expect(fixture.model.previewContent.errorMessage == nil)
        #expect(fixture.model.previewContent.status == .ready)
    }

    @Test("an unavailable summary cannot hide its real Full Return failure")
    func unavailableSummaryRetainsFullReadError() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("unavailable full history", at: Fixtures.epoch, in: fixture)
        #expect(fixture.model.enterPreview())
        let id = fixture.model.conversationID
        let session = try #require(fixture.model.previewContent.session)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE conversationID = ? AND kind = 'parent'",
                arguments: ["unknown-test-only-state", id])
        }
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.currentSummary?.contentUnavailable == true)
        #expect(fixture.model.previewContent.status == .contentUnavailable)
        #expect(fixture.model.previewContent.accessibilityLabel.contains("部分内容暂不可用"))
        #expect(!(await fixture.model.preparePreviewReturn()))
        let failure = try #require(fixture.model.previewContent.errorMessage)
        #expect(fixture.model.previewContent.status == .failed(failure))
        #expect(fixture.model.previewContent.accessibilityLabel.contains(failure))
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.errorMessage == failure)
        #expect(fixture.model.previewContent.isPresented && fixture.model.pane == nil)
        #expect(fixture.model.previewContent.session === session)
    }

    @Test("caller cancellation leaves Preview retryable without a storage error")
    func cancelledPreviewPreparationIsNotReadFailure() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "cancel-error", messageID: "cancel-error-user", runID: "cancel-error-run", runState: .completed))
        #expect(await fixture.model.openConversation(id: "cancel-error"))
        #expect(fixture.model.enterPreview())
        let session = try #require(fixture.model.previewContent.session)
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let operation = Task { await fixture.model.preparePreviewReturn() }
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(gate.hasBlocked)
        operation.cancel()
        gate.release()
        #expect(!(await operation.value))
        #expect(fixture.model.previewContent.isPresented && !fixture.model.previewContent.isPreparing)
        #expect(fixture.model.previewContent.session === session)
        #expect(fixture.model.previewContent.errorMessage == nil)
        #expect(fixture.model.previewContent.status == .ready)
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.pane?.session === session)
    }

    @Test("a failed Preview Return retains content and logical state for a real read retry")
    func previewReturnReadFailureAndRetry() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("history before Preview", at: Fixtures.epoch, in: fixture)
        let session = try #require(fixture.model.pane?.session)
        session.composer.draft.text = "retry keeps draft"
        #expect(fixture.model.enterPreview())
        let before = fixture.model.previewContent.summaries
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE message RENAME TO failed_preview_message") }
        #expect(!(await fixture.model.preparePreviewReturn()))
        #expect(fixture.model.previewContent.summaries == before)
        #expect(fixture.model.previewContent.errorMessage != nil)
        #expect(fixture.model.pane == nil)
        #expect(session.composer.draft.text == "retry keeps draft")
        let returnFailure = try #require(fixture.model.previewContent.errorMessage)
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.errorMessage == returnFailure)
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE failed_preview_message RENAME TO message") }
        fixture.model.refreshPreview()
        #expect(fixture.model.previewContent.errorMessage == returnFailure)
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.previewContent.errorMessage == nil)
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.pane?.session === session)
        #expect(fixture.model.previewContent.errorMessage == nil)
    }

    @Test("actual Streaming continues through Preview preparation and completes on the remounted owner")
    func previewStreamingHandoff() async throws {
        let box = Stage2StreamBox()
        let fixture = try makeFixture(seed: .active, scripts: [.holding(prefix: [.textDelta("before")], box: box)])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = fixture.model.conversationID
        let bridge = try #require(fixture.model.actionBridge)
        let runID = try await bridge.start(SendCommand(conversationID: id, text: "streaming Preview",
            providerInstanceID: fixture.instanceID, modelID: fixture.modelID, maxProviderSteps: 4,
            submissionID: "preview-streaming"))
        await box.waitUntilReady()
        for _ in 0..<100 {
            if try ConversationTimelineLoader.load(conversationID: id, from: fixture.store).turns
                .flatMap(\.items).contains(.assistantText("before")) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let session = try #require(fixture.model.pane?.session)
        let anchor = TurnAnchor(runID: runID, relativeViewportOffset: 0.2)
        session.readingPosition.setReadingAnchorForUITest(anchor)
        weak var oldPane = fixture.model.pane
        #expect(fixture.model.enterPreview())
        #expect(oldPane == nil && fixture.model.router.hasActiveRun(for: id))
        #expect(await fixture.model.preparePreviewReturn())
        #expect(box.cancellations == 0)
        box.yieldLate(.textDelta(" after"))
        box.yieldLate(.finish(.stop))
        try await fixture.runtime.waitForCompletion(runID: runID)
        #expect(fixture.model.pane == nil)
        #expect(fixture.model.commitPreviewReturn())
        let pane = try #require(fixture.model.pane)
        #expect(pane.session === session)
        #expect(pane.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText("before after")))
        if case .reading(let restored, _) = pane.readingPosition.mode { #expect(restored == anchor) }
        else { #expect(false, "Preview Return lost its reading anchor") }
        #expect(!fixture.model.router.hasActiveRun(for: id))
        #expect(try fixture.store.run(id: runID)?.state == .completed)
    }

    @Test("stable Preview releases its Pane/live store and returns the same logical session")
    func previewReleasesDisplayAndRestoresSession() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in try Fixtures.conversation(id: "preview-owner").insert(db) }
        #expect(await fixture.model.openConversation(id: "preview-owner"))
        let session = try #require(fixture.model.pane?.session)
        session.composer.draft.text = "你好 Preview draft"
        session.composer.draft.selection = ComposerSelection(range: 3..<10)
        let saved = session.composer.draft
        weak var oldPane = fixture.model.pane
        weak var oldStore = fixture.model.pane?.liveStore
        for _ in 0..<5 {
            #expect(fixture.model.enterPreview())
            #expect(fixture.model.pane == nil)
            #expect(fixture.model.actionBridge == nil)
            #expect(oldPane == nil && oldStore == nil)
            #expect(fixture.model.previewContent.isPresented)
            #expect(await fixture.model.preparePreviewReturn())
            // Preparation must not attach/render the Full Pane before the late handoff.
            #expect(fixture.model.pane == nil)
            #expect(fixture.model.commitPreviewReturn())
            #expect(fixture.model.pane?.session === session)
            #expect(fixture.model.pane?.composer.draft == saved)
            #expect(!fixture.model.previewContent.isPresented)
            oldPane = fixture.model.pane
            oldStore = fixture.model.pane?.liveStore
        }
    }

    @Test("Preview reads current plus three predecessors from 1000 histories and preserves Full on failure")
    func previewWindowIsBoundedAndReadFailureKeepsOwner() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<1_000 {
                let id = String(format: "preview-bounded-%04d", index)
                try Fixtures.conversation(id: id, title: "Preview \(index)").insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "preview-bounded-0050"))
        let trace = S504SQLTrace()
        try fixture.store.database.read { db in
            db.trace { event in if case .statement(let statement) = event { trace.record(statement.sql) } }
        }
        #expect(fixture.model.enterPreview())
        try fixture.store.database.read { db in db.trace(nil) }
        #expect(trace.selectCount <= 4)
        #expect(fixture.model.previewContent.summaries.map(\.id) == (50...53).map {
            String(format: "preview-bounded-%04d", $0)
        })
        #expect(try fixture.store.conversation(id: "preview-bounded-0050")?.userActiveAt == Fixtures.epoch)
        #expect(await fixture.model.openConversation(id: "preview-bounded-0051"))
        let full = try #require(fixture.model.pane)
        try fixture.store.database.write { db in try db.execute(sql: "DROP TABLE conversation") }
        #expect(!fixture.model.enterPreview())
        #expect(fixture.model.pane === full)
        #expect(fixture.model.previewContent.errorMessage != nil)
    }

    @Test("production SwiftUI Preview dismantles the actual native editor and remounts its UTF16 selection")
    func nativePreviewEditorReleaseAndSelection() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let session = try #require(fixture.model.pane?.session)
        session.composer.draft.text = "你好 🌍 draft selection"
        session.composer.draft.selection = ComposerSelection(range: 3..<5)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AppShellRootView(model: fixture.model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityIdentifier == "conversation-composer-input" { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<40 where editor(in: host.view) == nil { try await Task.sleep(for: .milliseconds(25)) }
        weak var oldEditor = try #require(editor(in: host.view))
        #expect(oldEditor?.selectedRange == NSRange(location: 3, length: 2))
        #expect(fixture.model.enterPreview())
        for _ in 0..<40 where editor(in: host.view) != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(editor(in: host.view) == nil)
        #expect(oldEditor == nil)
        #expect(await fixture.model.preparePreviewReturn())
        #expect(fixture.model.commitPreviewReturn())
        for _ in 0..<40 where editor(in: host.view) == nil { try await Task.sleep(for: .milliseconds(25)) }
        let remounted = try #require(editor(in: host.view))
        #expect(remounted.text == session.composer.draft.text)
        #expect(remounted.selectedRange == NSRange(location: 3, length: 2))
    }

    @Test("safe warm sessions are bounded while drafts survive cache pressure")
    func warmCacheReleasesOnlyReconstructibleSessions() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<15 {
                try Fixtures.conversation(id: "warm-budget-\(index)").insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "warm-budget-0"))
        weak var evictable = fixture.model.pane?.session
        #expect(await fixture.model.openConversation(id: "warm-budget-1"))
        weak var protected = fixture.model.pane?.session
        fixture.model.pane?.composer.draft.text = "unsaved draft"
        for index in 2..<15 {
            #expect(await fixture.model.openConversation(id: "warm-budget-\(index)"))
        }
        #expect(evictable == nil)
        #expect(protected != nil)
        #expect(await fixture.model.openConversation(id: "warm-budget-1"))
        #expect(fixture.model.pane?.session === protected)
        #expect(fixture.model.pane?.composer.draft.text == "unsaved draft")
        #expect(await fixture.model.openConversation(id: "warm-budget-0"))
        #expect(fixture.model.pane?.composer.draft.text == "")
    }

    @Test("warm sessions with changed configuration and reading anchors exceed the safe cache budget")
    func warmCacheProtectsConfigurationAndReading() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<25 {
                try Fixtures.conversation(id: "protected-budget-\(index)").insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "protected-budget-0"))
        weak var configurationOwner = fixture.model.pane?.session
        let chosen = ConversationComposerConfiguration(providerInstanceID: fixture.instanceID,
            modelID: fixture.modelID)
        fixture.model.pane?.composer.configuration = chosen
        #expect(await fixture.model.openConversation(id: "protected-budget-1"))
        weak var readingOwner = fixture.model.pane?.session
        let anchor = TurnAnchor(runID: "reading-turn", relativeViewportOffset: -0.5)
        _ = fixture.model.pane?.readingPosition.apply(.userScrolled(
            geometry: ScrollGeometry(viewportHeight: 500, contentHeight: 1500, offset: 100),
            anchor: anchor))
        for index in 2..<25 {
            #expect(await fixture.model.openConversation(id: "protected-budget-\(index)"))
            fixture.model.pane?.composer.draft.text = "draft \(index)"
        }
        #expect(configurationOwner != nil)
        #expect(readingOwner != nil)
        #expect(await fixture.model.openConversation(id: "protected-budget-0"))
        #expect(fixture.model.pane?.session === configurationOwner)
        #expect(fixture.model.pane?.composer.configuration == chosen)
        #expect(await fixture.model.openConversation(id: "protected-budget-1"))
        #expect(fixture.model.pane?.session === readingOwner)
        #expect(fixture.model.pane?.readingPosition.mode == .reading(anchor: anchor, pendingTurns: []))
        #expect(await fixture.model.openConversation(id: "protected-budget-2"))
        #expect(fixture.model.pane?.composer.draft.text == "draft 2")
    }

    @Test("warm cache protects active routes until terminal events and releases them under pressure")
    func warmCacheProtectsActiveRoute() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<25 {
                try Fixtures.conversation(id: "active-budget-\(index)").insert(db)
            }
        }
        #expect(await fixture.model.openConversation(id: "active-budget-0"))
        weak var owner = fixture.model.pane?.session
        fixture.model.router.registerRecoveredRun(runID: "protected-active-run",
            conversationID: "active-budget-0")
        for index in 1..<13 {
            #expect(await fixture.model.openConversation(id: "active-budget-\(index)"))
        }
        #expect(owner != nil)
        await fixture.model.router.handle(.runEnded(runID: "protected-active-run",
            state: .completed, endReason: .completed))
        for index in 13..<25 {
            #expect(await fixture.model.openConversation(id: "active-budget-\(index)"))
        }
        #expect(owner == nil)
    }

    @Test("Recent Full Open failure stays visible across summary refresh and retries the same history",
          arguments: ["metadata", "sql"])
    func recentFullOpenFailureIsVisible(kind: String) async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = "recent-full-error"
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: id, messageID: "recent-error-user", runID: "recent-error-run", runState: .completed))
        fixture.model.refreshRecentConversations()
        let outgoingID = fixture.model.conversationID
        let outgoingPane = fixture.model.pane
        let outgoingSession = fixture.model.pane?.session
        if kind == "metadata" {
            try fixture.store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                    arguments: ["unknown-recent-test-state", "recent-error-run"])
            }
            fixture.model.refreshRecentConversations()
            #expect(fixture.model.recentConversations.first { $0.id == id }?.contentUnavailable == true)
        } else {
            // The bounded summary still looks healthy; only the real full-history SQL fails.
            try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE toolCall RENAME TO failed_recent_toolCall") }
        }
        #expect(!(await fixture.model.openConversation(id: id)))
        #expect(fixture.model.recentLoadError != nil)
        #expect(fixture.model.conversationID == outgoingID)
        #expect(fixture.model.pane === outgoingPane)
        #expect(fixture.model.pane?.session === outgoingSession)
        let failure = fixture.model.recentLoadError
        fixture.model.refreshRecentConversations()
        #expect(fixture.model.recentLoadError == failure)
        try fixture.store.database.write { db in
            if kind == "metadata" {
                try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                    arguments: [RunState.completed.rawValue, "recent-error-run"])
            } else {
                try db.execute(sql: "ALTER TABLE failed_recent_toolCall RENAME TO toolCall")
            }
        }
        fixture.model.refreshRecentConversations()
        #expect(fixture.model.recentLoadError == failure)
        #expect(await fixture.model.openConversation(id: id))
        #expect(fixture.model.conversationID == id)
        #expect(fixture.model.recentLoadError == nil)
    }

    @Test("cancelled Recent Open preserves its owner without presenting a read failure")
    func cancelledRecentOpenHasNoReadFailure() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "recent-cancel", messageID: "recent-cancel-user", runID: "recent-cancel-run", runState: .completed))
        fixture.model.refreshRecentConversations()
        let outgoingID = fixture.model.conversationID
        let outgoingPane = fixture.model.pane
        let gate = PreviewReadGate()
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let opening = Task { await fixture.model.openConversation(id: "recent-cancel") }
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(gate.hasBlocked)
        opening.cancel()
        gate.release()
        #expect(!(await opening.value))
        #expect(!gate.timedOut)
        #expect(fixture.model.recentLoadError == nil)
        #expect(fixture.model.conversationID == outgoingID)
        #expect(fixture.model.pane === outgoingPane)
    }

    @Test("Recent presentation publishes typed corruption readiness")
    func recentContentReadinessIsTyped() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "typed-readiness").insert(db)
            try Fixtures.message(id: "typed-message", conversationID: "typed-readiness").insert(db)
            try Fixtures.textPart(id: "typed-part", messageID: "typed-message", text: "content").insert(db)
            try db.execute(sql: "UPDATE messagePart SET payload = ? WHERE id = ?",
                arguments: ["{broken", "typed-part"])
        }
        fixture.model.refreshRecentConversations()
        let summary = try #require(fixture.model.recentConversations.first { $0.id == "typed-readiness" })
        #expect(summary.previewStatus == .contentUnavailable)
        #expect(summary.contentUnavailable)
    }

    @Test("recent next-page failure preserves its cursor and retry loads that same page")
    func recentPaginationRetriesFailedPage() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<101 {
                let id = String(format: "paged-recent-%04d", index)
                try Fixtures.conversation(id: id, title: "Page \(index)").insert(db)
            }
        }
        fixture.model.refreshRecentConversations()
        #expect(fixture.model.recentConversations.count == 50)
        #expect(fixture.model.recentHasMore)
        let firstPage = fixture.model.recentConversations
        try fixture.store.database.write { db in try db.execute(sql: "DROP TABLE messagePart") }
        fixture.model.loadMoreRecentConversations()
        #expect(fixture.model.recentConversations == firstPage)
        #expect(fixture.model.recentLoadError != nil)
        #expect(fixture.model.recentHasMore)
        // Restore the actual empty fixture table, then retry the failed page.
        try fixture.store.database.write { db in
            try db.execute(sql: """
                CREATE TABLE messagePart (
                    id TEXT PRIMARY KEY, messageID TEXT NOT NULL REFERENCES message(id),
                    sequence INTEGER NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX messagePart_by_message ON messagePart(messageID, sequence)")
        }
        fixture.model.retryRecentConversations()
        #expect(fixture.model.recentConversations.count == 100)
        #expect(fixture.model.recentLoadError == nil)
        #expect(fixture.model.recentHasMore)
        fixture.model.loadMoreRecentConversations()
        #expect(fixture.model.recentConversations.count == 101)
        #expect(!fixture.model.recentHasMore)
        #expect(Set(fixture.model.recentConversations.map(\.id)).count == 101)
        #expect(fixture.model.recentConversations.first?.id == "paged-recent-0000")
        #expect(fixture.model.recentConversations.last?.id == "paged-recent-0100")
    }

    @Test("recent read failure preserves loaded rows and exposes retry instead of empty history")
    func recentFailurePreservesRows() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "recent-survives-read-error", title: "Saved title").insert(db)
        }
        fixture.model.refreshRecentConversations()
        let previous = fixture.model.recentConversations
        #expect(previous.count == 1)
        try fixture.store.database.write { db in try db.execute(sql: "DROP TABLE conversation") }
        fixture.model.refreshRecentConversations()
        #expect(fixture.model.recentConversations == previous)
        #expect(fixture.model.recentLoadError != nil)
    }

    @Test("recent entry reads a bounded first page without per-conversation title queries",
          arguments: [100, 1_000])
    func recentFirstPageIsBounded(historyCount: Int) throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            for index in 0..<historyCount {
                let id = String(format: "bounded-recent-%04d", index)
                try Fixtures.conversation(id: id, title: "").insert(db)
                let messageID = "user-\(id)"
                try Fixtures.message(id: messageID, conversationID: id).insert(db)
                try Fixtures.textPart(id: "part-\(id)", messageID: messageID,
                    text: "  question \(index)  ").insert(db)
            }
            try Fixtures.conversation(id: "hidden-recent", lifecycle: .pendingDeletion).insert(db)
        }
        let trace = S504SQLTrace()
        try fixture.store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event { trace.record(statement.sql) }
            }
        }
        let clock = ContinuousClock()
        let begin = clock.now
        fixture.model.refreshRecentConversations()
        let elapsed = begin.duration(to: clock.now)
        try fixture.store.database.read { db in db.trace(nil) }
        #expect(fixture.model.recentConversations.count == 50)
        #expect(trace.selectCount <= 2)
        let first = try #require(fixture.model.recentConversations.first)
        #expect(first.id == "bounded-recent-0000")
        #expect(first.title == "question 0")
        #expect(!fixture.model.recentConversations.contains { $0.id == "hidden-recent" })
        #expect(try fixture.store.conversation(id: first.id)?.userActiveAt == Fixtures.epoch)
        print("S504 existing Recent rows=\(historyCount) returned=\(fixture.model.recentConversations.count) SELECTs=\(trace.selectCount) elapsed=\(elapsed)")
    }

    @Test("late send preflight failure updates its original session even when targets match")
    func lateTargetFailureKeepsConversationOwner() async throws {
        let fixture = try makeFixture(seed: .active, scripts: [.events([]), .events([])])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("persist A", at: Fixtures.epoch, in: fixture)
        let firstID = fixture.model.conversationID
        let firstPane = try #require(fixture.model.pane)
        let firstBridge = try #require(fixture.model.actionBridge)
        firstPane.composer.draft.text = "pending A follow-up"
        let coordinator = ComposerSendCoordinator(conversationID: firstID, controller: firstPane.composer,
            configuration: firstPane.composer.configuration, bridge: firstBridge,
            maxProviderSteps: AppShellModel.maxProviderSteps)
        let command = try #require(coordinator.beginSend(capabilities: [.text, .streaming],
            quoteCommitReady: true, imageInputReady: false, fileInputReady: false,
            submissionID: "late-owner-\(UUID().uuidString)"))

        fixture.model.newConversation()
        try await send("persist B", at: Fixtures.epoch.addingTimeInterval(1), in: fixture)
        let secondPane = try #require(fixture.model.pane)
        #expect(secondPane.composer.configuration == firstPane.composer.configuration)
        #expect(secondPane.composer.sendAvailability.isReady)
        // A prepared command's asynchronous preflight arrives after navigation.
        // The real old bridge retains A's owner identity, not B's current display.
        fixture.backend.unreadableReferences = [fixture.reference.id]
        do {
            _ = try await firstBridge.start(command)
            Issue.record("old command should fail before creating another Run")
        } catch let failure as ComposerSendFailure {
            guard case .keychainUnavailable = failure else {
                Issue.record("unexpected preflight failure: \(failure)")
                return
            }
        }
        #expect(firstPane.composer.sendAvailability == .unavailable("Keychain 不可用"))
        #expect(secondPane.composer.sendAvailability.isReady)
        #expect(fixture.model.canSend)
        #expect(try fixture.store.runs(inConversation: firstID).count == 1)
        #expect(firstPane.composer.draft.text == "pending A follow-up")
    }

    @Test("warm A B A navigation retains each session's configuration draft and reading owner")
    func warmNavigationRetainsSessionOwners() async throws {
        let fixture = try makeFixture(seed: .active, scripts: [.events([]), .events([])])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("first persisted question", at: Fixtures.epoch, in: fixture)
        let firstID = fixture.model.conversationID
        let firstPane = try #require(fixture.model.pane)
        let firstComposer = firstPane.composer
        let firstReading = firstPane.readingPosition
        let committed = try #require(try fixture.store.runs(inConversation: firstID).first)
        let frozenSeed = committed.requestConfigSeed
        let chosen = ConversationComposerConfiguration(providerInstanceID: fixture.instanceID,
            modelID: ModelID(rawValue: "warm-session-unavailable-model"))
        firstComposer.configuration = chosen
        let quote = QuoteReference(id: "warm-session-quote", source: QuoteSourceLocator(
            sourceConversationID: firstID, sourceMessageID: "source-message", sourcePartID: "source-part",
            range: QuoteTextRange(utf16Start: 0, utf16Length: 6)), snapshot: "quoted", createdAt: Fixtures.epoch)
        let firstDraft = ComposerDraftState(text: "A follow-up", selection: ComposerSelection(range: 2..<6),
            references: [quote], attachments: [AttachmentReference(id: "warm-file", versionID: "v1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))", displayName: "notes.pdf", kind: .file)],
            presentationState: .compact)
        firstComposer.draft = firstDraft
        let anchor = TurnAnchor(runID: committed.id, relativeViewportOffset: -0.25)
        firstReading.setReadingAnchorForUITest(anchor)

        fixture.model.newConversation()
        try await send("second persisted question", at: Fixtures.epoch.addingTimeInterval(1), in: fixture)
        let secondID = fixture.model.conversationID
        let secondPane = try #require(fixture.model.pane)
        let secondComposer = secondPane.composer
        secondComposer.draft.text = "B follow-up"
        let secondDraft = secondComposer.draft

        #expect(await fixture.model.openConversation(id: firstID))
        let reopened = try #require(fixture.model.pane)
        #expect(reopened.composer === firstComposer)
        #expect(reopened.readingPosition === firstReading)
        #expect(reopened.composer.draft == firstDraft)
        #expect(reopened.composer.configuration == chosen)
        #expect(reopened.readingPosition.mode == .reading(anchor: anchor, pendingTurns: []))
        #expect(reopened.scrollRequest?.action == .restoreAnchor(anchor))
        #expect(!reopened.composer.sendAvailability.isReady)

        let setup = try #require(fixture.model.providerSetup)
        setup.apiKey = "sk-warm-session-test"
        #expect(setup.save())
        #expect(reopened.composer.configuration == chosen)
        #expect(try fixture.store.run(id: committed.id)?.requestConfigSeed == frozenSeed)
        #expect(await fixture.model.openConversation(id: secondID))
        #expect(fixture.model.pane?.composer === secondComposer)
        #expect(fixture.model.pane?.composer.draft == secondDraft)
        #expect(try conversationCount(in: fixture.store) == 2)
    }

    @Test(
        "local history opens independently of send configuration",
        arguments: [
            ShellCredentialSeed.none,
            .missingSecret,
            .unreadableSecret,
        ]
    )
    func historyOpensWithoutSendTarget(_ seed: ShellCredentialSeed) async throws {
        let unconfigured = seed == .none
        let fixture = try makeFixture(
            seed: seed,
            createInstance: !unconfigured,
            setDefault: !unconfigured
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let conversationID = "saved-\(UUID().uuidString)"
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: conversationID,
            messageID: "user-\(conversationID)",
            runID: "run-\(conversationID)",
            runState: .completed
        ))
        fixture.model.refreshRecentConversations()

        #expect(fixture.model.recentConversations.map(\.id).contains(conversationID))
        #expect(await fixture.model.openConversation(id: conversationID))
        #expect(fixture.model.conversationID == conversationID)
        #expect(fixture.model.pane?.liveStore.state.timeline.turns.count == 1)
        #expect(!fixture.model.canSend)
        #expect(try fixture.store.visibleConversations().count == 1)
    }

    @Test("configuring after offline reading preserves the same Pane and full Draft")
    func configuringAfterOfflineReadingPreservesDraft() async throws {
        let fixture = try makeFixture(seed: .none, createInstance: false, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        let quote = QuoteReference(
            id: "offline-quote",
            source: QuoteSourceLocator(
                sourceConversationID: "source-conversation",
                sourceMessageID: "source-message",
                sourcePartID: "source-part",
                range: QuoteTextRange(utf16Start: 0, utf16Length: 6)
            ),
            snapshot: "quoted",
            createdAt: Fixtures.epoch
        )
        let draft = ComposerDraftState(
            text: "keep this draft",
            selection: ComposerSelection(range: 5..<9),
            references: [quote],
            attachments: [AttachmentReference(
                id: "offline-file",
                versionID: "version-1",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))",
                displayName: "notes.pdf",
                kind: .file
            )],
            presentationState: .editing
        )
        pane.composer.draft = draft
        let coordinator = ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: nil,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        )
        #expect(coordinator.beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "offline-unsendable"
        ) == nil)
        _ = await coordinator.handlePrimaryAction()
        #expect(coordinator.sendErrorMessage == "尚未配置模型")
        #expect(try conversationCount(in: fixture.store) == 0)

        let setup = try #require(fixture.model.providerSetup)
        setup.apiKey = "sk-configured-after-reading"
        #expect(setup.save())
        #expect(fixture.model.canSend)
        #expect(fixture.model.pane === pane)
        #expect(pane.composer.draft == draft)
        #expect(pane.composer.configuration != nil)
        #expect(try conversationCount(in: fixture.store) == 0)
    }

    @Test("cold launch settles an orphaned streaming run without replaying its provider request")
    func coldLaunchSettlesOrphanedStreamingRun() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-cold-start-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let runID = "orphan-\(UUID().uuidString)"
        let conversationID = "conversation-\(runID)"
        let partID = "partial-\(runID)"

        do {
            let firstStore = PersistenceStore(database: try ZenDatabase.open(at: url.path))
            try firstStore.commitUserTurnAndCreateParentRun(Fixtures.send(
                conversationID: conversationID,
                messageID: "user-\(runID)",
                runID: runID,
                runState: .streaming
            ))
            let response = try firstStore.ensureAssistantResponse(
                forRunID: runID,
                messageID: "assistant-\(runID)"
            )
            try firstStore.createPart(Fixtures.streamingPart(
                id: partID,
                messageID: response.id,
                text: "preserved partial"
            ))
        }

        let reopenedStore = PersistenceStore(database: try ZenDatabase.open(at: url.path))
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: ledger, scripts: [.events([.finish(.stop)])])
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: reopenedStore,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: reopenedStore,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.ColdStart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shell = AppShellModel(dependencies: dependencies, userDefaults: defaults)
        for _ in 0..<100 {
            if try reopenedStore.run(id: runID)?.state == .failed,
               shell.launchState == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(try reopenedStore.run(id: runID))
        #expect(shell.launchState == .ready)
        #expect(run.state == .failed)
        #expect(run.endReason == .streamInterrupted)
        #expect(try reopenedStore.text(ofPart: partID) == "preserved partial")
        #expect(try reopenedStore.parts(ofMessage: "assistant-\(runID)").first?.state == .failed)
        #expect(try reopenedStore.activeParentRuns(inConversation: conversationID).isEmpty)
        #expect(await ledger.requestsSnapshot().isEmpty)
    }

    @Test("zeroConfigurationDoesNotCreateConversationOrEnableSend")
    func zeroConfigurationDoesNotCreateConversationOrEnableSend() throws {
        let fixture = try makeFixture(seed: .none, createInstance: false, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let initialCount = try conversationCount(in: fixture.store)
        let originalConversationID = fixture.model.conversationID
        fixture.model.newConversation()
        let finalCount = try conversationCount(in: fixture.store)

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane != nil)
        #expect(fixture.model.pane?.composer.configuration == nil)
        #expect(fixture.model.actionBridge != nil)
        #expect(fixture.model.conversationID != originalConversationID)
        #expect(initialCount == 0)
        #expect(finalCount == 0)
        #expect(fixture.model.recentConversations.isEmpty)
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("defaultTargetRequiresKnownModelAndResolvedSecret")
    func defaultTargetRequiresKnownModelAndResolvedSecret() throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let instance = try #require(try fixture.store.providerInstance(id: fixture.instanceID))
        let metadata = try #require(try fixture.credentials.metadata(for: fixture.reference))
        let descriptors = fixture.provider.knownModels(for: instance)
        let resolved = try #require(try fixture.credentials.resolve(
            frozenReference: metadata.reference,
            generation: metadata.bindingGeneration
        ))

        #expect(descriptors.contains { $0.id == fixture.modelID })
        #expect(resolved.revealed == fixture.secret)
        #expect(fixture.model.canSend)
        #expect(fixture.model.target == AppExecutionTarget(
            providerInstanceID: fixture.instanceID,
            modelID: fixture.modelID
        ))
    }

    @Test("missingSecretIsNotSendableAndExplained")
    func missingSecretIsNotSendableAndExplained() throws {
        let fixture = try makeFixture(seed: .missingSecret)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane != nil)
        #expect(fixture.model.target == AppExecutionTarget(
            providerInstanceID: fixture.instanceID,
            modelID: fixture.modelID
        ))
        #expect(fixture.model.targetMessage == "Key 缺失")
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("unavailableSecretIsNotSendableAndExplainedSeparately")
    func unavailableSecretIsNotSendableAndExplainedSeparately() throws {
        let fixture = try makeFixture(seed: .unreadableSecret)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        #expect(!fixture.model.canSend)
        #expect(fixture.model.pane != nil)
        #expect(fixture.model.target == AppExecutionTarget(
            providerInstanceID: fixture.instanceID,
            modelID: fixture.modelID
        ))
        #expect(fixture.model.targetMessage == "Keychain 不可用")
        #expect(fixture.model.targetMessage != "Key 缺失")
    }

    @Test("sendPreflightRechecksKeychainAndDisablesTheTarget")
    func sendPreflightRechecksKeychainAndDisablesTheTarget() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        pane.composer.draft.text = "keep after keychain failure"
        fixture.backend.unreadableReferences = [fixture.reference.id]
        let coordinator = ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(!fixture.model.canSend)
        #expect(fixture.model.targetMessage == "Keychain 不可用")
        #expect(coordinator.sendErrorMessage == "Keychain 不可用")
        #expect(coordinator.submission == .idle)
        #expect(pane.composer.draft.text == "keep after keychain failure")
        #expect(try fixture.store.conversation(id: fixture.model.conversationID) == nil)
    }

    @Test("firstSendPersistsOneTurnAndParentRun")
    func firstSendPersistsOneTurnAndParentRun() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        pane.composer.draft.text = "first turn"
        pane.composer.draft.selection = ComposerSelection(range: 0..<pane.composer.draft.text.count)
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let command = try #require(ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        ).beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "w1-first-send-submission"
        ))

        let runID = try await ComposerSendTiming.$initiatedAt.withValue(timestamp) {
            try await bridge.start(command)
        }
        try await fixture.runtime.waitForCompletion(runID: runID)

        let conversation = try #require(try fixture.store.conversation(id: command.conversationID))
        let messages = try fixture.store.messages(inConversation: command.conversationID)
        let userMessage = try #require(messages.first)
        let parts = try fixture.store.parts(ofMessage: userMessage.id)
        let parentRuns = try fixture.store.runs(inConversation: command.conversationID)
            .filter { $0.kind == .parent }

        #expect(messages.count == 1)
        #expect(userMessage.role == .user)
        #expect(parts.count == 1)
        #expect(try fixture.store.text(ofPart: parts[0].id) == command.text)
        #expect(parentRuns.count == 1)
        #expect(parentRuns[0].id == runID)
        #expect(parentRuns[0].submissionID == command.submissionID)
        #expect(conversation.title == "")
        #expect(conversation.lifecycle == .visible)
        #expect(!conversation.pinned)
        #expect(conversation.createdAt == timestamp)
        #expect(conversation.updatedAt == timestamp)
        #expect(conversation.userActiveAt == timestamp)
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == [runID])
        #expect(pane.liveStore.state.timeline.turns[0].items.contains(.userText(command.text)))

        fixture.model.refreshRecentConversations()
        let recent = try #require(fixture.model.recentConversations.first)
        #expect(recent.id == command.conversationID)
        #expect(recent.title == "first turn")
    }

    @Test("reconstructed shell lists recent conversations and opens the selected persisted timeline")
    func reconstructedShellOpensSelectedRecentConversation() async throws {
        let fixture = try makeFixture(
            seed: .active,
            scripts: [
                .events([.textDelta("first answer"), .finish(.stop)]),
                .events([.textDelta("second answer"), .finish(.stop)])
            ]
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let firstConversationID = fixture.model.conversationID
        try await send("first question", at: Date(timeIntervalSince1970: 1_790_000_100), in: fixture)

        fixture.model.newConversation()
        let secondConversationID = fixture.model.conversationID
        #expect(fixture.model.recentConversations.map(\.id) == [firstConversationID])
        try await send("second question", at: Date(timeIntervalSince1970: 1_790_000_200), in: fixture)
        fixture.model.refreshRecentConversations()

        let reconstructed = await makeReconstructedModel(from: fixture)
        #expect(reconstructed.recentConversations.map(\.id) == [
            secondConversationID,
            firstConversationID
        ])
        let selected = try #require(reconstructed.recentConversations.last)
        #expect(selected.id == firstConversationID)
        #expect(await reconstructed.openConversation(id: selected.id))

        let pane = try #require(reconstructed.pane)
        let timeline = pane.liveStore.state.timeline
        let items = timeline.turns.flatMap(\.items)
        #expect(items.contains(.userText("first question")))
        #expect(items.contains(.assistantText("first answer")))
        #expect(!items.contains(.userText("second question")))
        #expect(!items.contains(.assistantText("second answer")))
    }

    @Test("repeat send uses the user's action time and survives shell reconstruction")
    func repeatSendAdvancesRecentActivity() async throws {
        let fixture = try makeFixture(
            seed: .active,
            scripts: [
                .events([.textDelta("A answer"), .finish(.stop)]),
                .events([.textDelta("B answer"), .finish(.stop)]),
                .events([.textDelta("A follow-up"), .finish(.stop)])
            ]
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let t1 = Date(timeIntervalSince1970: 1_790_000_100)
        let t2 = t1.addingTimeInterval(60)
        let t3 = t2.addingTimeInterval(60)
        let firstID = fixture.model.conversationID
        try await send("A first", at: t1, in: fixture)
        fixture.model.newConversation()
        let secondID = fixture.model.conversationID
        try await send("B first", at: t2, in: fixture)

        #expect(await fixture.model.openConversation(id: firstID))
        #expect(try fixture.store.conversation(id: firstID)?.userActiveAt == t1)
        try await send("A again", at: t3, in: fixture)

        let reopenedShell = await makeReconstructedModel(from: fixture)
        let first = try #require(try fixture.store.conversation(id: firstID))
        #expect(reopenedShell.recentConversations.map(\.id) == [firstID, secondID])
        #expect(first.createdAt == t1)
        #expect(first.userActiveAt == t3)
        #expect(first.updatedAt == t3)
        #expect(try fixture.store.messages(inConversation: firstID)
            .filter { $0.role == .user }.last?.createdAt == t3)
    }

    @Test("cold launch restores a visible conversation within twenty minutes")
    func coldLaunchRestoresRecentConversation() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let conversationID = fixture.model.conversationID
        try await send("restore me", at: Date(), in: fixture)
        fixture.model.enteredBackground(at: Date())

        let reconstructed = await makeReconstructedModel(from: fixture)

        #expect(reconstructed.conversationID == conversationID)
        #expect(reconstructed.pane?.liveStore.state.timeline.turns.count == 1)
        #expect(ConversationResumeMarker.read(from: fixture.defaults) == nil)
        #expect(try conversationCount(in: fixture.store) == 1)
    }

    @Test("a temporary Timeline read failure keeps the cold-launch marker")
    func unreadableTimelineKeepsRestoreMarker() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let conversationID = fixture.model.conversationID
        try await send("restore after read retry", at: Date(), in: fixture)
        fixture.model.enteredBackground(at: Date())
        let marker = try #require(ConversationResumeMarker.read(from: fixture.defaults))
        try fixture.store.database.write { db in
            try db.execute(sql: "ALTER TABLE messagePart RENAME TO messagePart_temporarily_unavailable")
        }

        let reconstructed = await makeReconstructedModel(from: fixture)

        #expect(reconstructed.conversationID != conversationID)
        #expect(ConversationResumeMarker.read(from: fixture.defaults) == marker)
        #expect(try fixture.store.conversationLifecycle(id: conversationID) == .visible)
    }

    @Test("expired cold launch enters a new blank page and keeps the old conversation reachable")
    func expiredColdLaunchStartsNewConversation() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let oldID = fixture.model.conversationID
        try await send("old conversation", at: Date(), in: fixture)
        fixture.model.enteredBackground(at: Date().addingTimeInterval(-1_201))

        let reconstructed = await makeReconstructedModel(from: fixture)

        #expect(reconstructed.conversationID != oldID)
        #expect(reconstructed.pane?.liveStore.state.timeline.turns.isEmpty == true)
        #expect(reconstructed.recentConversations.contains { $0.id == oldID })
        #expect(try fixture.store.conversation(id: reconstructed.conversationID) == nil)
        #expect(await reconstructed.openConversation(id: oldID))
        #expect(reconstructed.pane?.liveStore.state.timeline.turns.count == 1)
    }

    @Test("warm timeout keeps an unsent draft in process for reopening the old conversation")
    func warmTimeoutRetainsDraft() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let oldID = fixture.model.conversationID
        try await send("persisted question", at: Date(), in: fixture)
        let oldPane = try #require(fixture.model.pane)
        oldPane.composer.draft.text = "unsent follow-up"
        oldPane.composer.draft.selection = ComposerSelection(range: 0..<16)
        let backgroundedAt = Date(timeIntervalSince1970: 1_790_000_000)

        fixture.model.enteredBackground(at: backgroundedAt)
        fixture.model.becameActive(at: backgroundedAt.addingTimeInterval(1_201))

        #expect(fixture.model.conversationID != oldID)
        #expect(fixture.model.pane?.composer.draft.text == "")
        #expect(fixture.model.recentConversations.contains { $0.id == oldID })
        #expect(await fixture.model.openConversation(id: oldID))
        #expect(fixture.model.pane?.composer.draft.text == "unsent follow-up")
        #expect(try conversationCount(in: fixture.store) == 1)
    }

    @Test("warm return inside the window keeps the current pane and draft")
    func warmReturnKeepsCurrentPane() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try await send("persisted question", at: Date(), in: fixture)
        let originalID = fixture.model.conversationID
        let originalPane = try #require(fixture.model.pane)
        originalPane.composer.draft.text = "continue"
        let backgroundedAt = Date(timeIntervalSince1970: 1_790_000_000)

        fixture.model.enteredBackground(at: backgroundedAt)
        fixture.model.becameActive(at: backgroundedAt.addingTimeInterval(1_200))

        #expect(fixture.model.conversationID == originalID)
        #expect(fixture.model.pane === originalPane)
        #expect(fixture.model.pane?.composer.draft.text == "continue")
        #expect(ConversationResumeMarker.read(from: fixture.defaults) == nil)
    }

    @Test("cold launch will not restore a conversation hidden after backgrounding")
    func hiddenConversationDoesNotRestore() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let oldID = fixture.model.conversationID
        try await send("to be hidden", at: Date(), in: fixture)
        fixture.model.enteredBackground(at: Date())
        try fixture.store.beginDeletion(conversationID: oldID)

        let reconstructed = await makeReconstructedModel(from: fixture)

        #expect(reconstructed.conversationID != oldID)
        #expect(!reconstructed.recentConversations.contains { $0.id == oldID })
        #expect(try conversationCount(in: fixture.store) == 1)
    }

    @Test("recent entry excludes hidden conversations and refuses stale hidden selections")
    func recentEntryExcludesPendingAndFinalizedDeletion() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let conversationIDs = ["visible-z", "visible-a", "pending-hidden", "finalized-hidden"]
        try fixture.store.database.write { db in
            for id in conversationIDs {
                var conversation = Fixtures.conversation(id: id, title: "Title for \(id)")
                conversation.userActiveAt = Date(timeIntervalSince1970: 1_790_000_300)
                try conversation.insert(db)
            }
        }
        try fixture.store.beginDeletion(conversationID: "pending-hidden")
        try fixture.store.beginDeletion(conversationID: "finalized-hidden")
        try fixture.store.finalizeDeletion(conversationID: "finalized-hidden")

        fixture.model.refreshRecentConversations()

        #expect(fixture.model.recentConversations.map(\.id) == ["visible-a", "visible-z"])
        let currentConversationID = fixture.model.conversationID
        #expect(!(await fixture.model.openConversation(id: "pending-hidden")))
        #expect(!(await fixture.model.openConversation(id: "finalized-hidden")))
        #expect(fixture.model.conversationID == currentConversationID)
        #expect(fixture.model.launchState == .ready)
    }

    @Test("runAcceptedLoadsOwningPaneBeforeRoutingLaterDeltas")
    func runAcceptedLoadsOwningPaneBeforeRoutingLaterDeltas() async throws {
        let router = RunEventRouter()
        var paneALoadCount = 0
        let paneA = try makePane(conversationID: "route-conversation-A") { id -> ConversationTimelineProjection in
            paneALoadCount += 1
            return ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "route-run-A", items: [.userText("first A")])]
            )
        }
        let paneB = try makePane(conversationID: "route-conversation-B") { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "route-run-B", items: [.userText("first B")])]
            )
        }
        #expect(router.registerPane(paneA))
        try paneB.reloadTimeline()
        #expect(router.registerPane(paneB))

        await router.handle(.runAccepted(runID: "route-run-A", conversationID: "route-conversation-A"))
        #expect(paneALoadCount == 1)
        _ = await router.handle(.messagePartStarted(
            runID: "route-run-A",
            messageID: "route-message-A",
            partID: "route-part-A",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "route-run-A", partID: "route-part-A", delta: "reply A", endUTF8Offset: 7))

        #expect(paneA.liveStore.state.timeline.turns.map(\.runID) == ["route-run-A"])
        #expect(assistantTexts(in: paneA.liveStore.state.timeline) == ["reply A"])
        #expect(paneB.liveStore.state.timeline.turns.map(\.runID) == ["route-run-B"])
        #expect(paneB.liveStore.state.timeline.turns[0].items == [.userText("first B")])
    }

    @Test("eventsWaitingForPaneRebuildFromPersistedTimelineInArrivalOrder")
    func eventsWaitingForPaneRebuildFromPersistedTimelineInArrivalOrder() async throws {
        let router = RunEventRouter()
        await router.handle(.runAccepted(runID: "buffered-run", conversationID: "buffered-conversation"))
        await router.handle(.messagePartStarted(
            runID: "buffered-run",
            messageID: "buffered-message",
            partID: "buffered-part",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "buffered-run", partID: "buffered-part", delta: "saved reply", endUTF8Offset: 11))

        let pane = try makePane(conversationID: "buffered-conversation") { id in
            persistedTimeline(
                conversationID: id,
                runID: "buffered-run",
                messageID: "buffered-message",
                partID: "buffered-part",
                assistantText: "saved reply"
            )
        }
        #expect(router.registerPane(pane))

        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["buffered-run"])
        #expect(assistantTexts(in: pane.liveStore.state.timeline) == ["saved reply"])
        #expect(pane.liveStore.state.timeline.turns[0].items.filter { item -> Bool in
            if case .assistantText = item { return true }
            return false
        }.count == 1)
    }

    @Test("timelineLoadFailureRetainsOwnershipAndRecoversBufferedEvents")
    func timelineLoadFailureRetainsOwnershipAndRecoversBufferedEvents() async throws {
        let router = RunEventRouter()
        var loadCount = 0
        let pane = try makePane(conversationID: "recover-conversation") { id -> ConversationTimelineProjection in
            loadCount += 1
            if loadCount == 1 { throw RouterLoadFailure.unavailable }
            return persistedTimeline(
                conversationID: id,
                runID: "recover-run",
                messageID: "recover-message",
                partID: "recover-part",
                assistantText: "recovered reply"
            )
        }
        #expect(router.registerPane(pane))

        await router.handle(.runAccepted(runID: "recover-run", conversationID: "recover-conversation"))
        await router.handle(.messagePartStarted(
            runID: "recover-run",
            messageID: "recover-message",
            partID: "recover-part",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "recover-run", partID: "recover-part", delta: "recovered reply", endUTF8Offset: 15))

        #expect(router.recoveryMessage(for: "recover-conversation") != nil)
        #expect(loadCount == 1)
        #expect(await router.retryTimelineLoad(for: "recover-conversation"))
        #expect(router.recoveryMessage(for: "recover-conversation") == nil)
        #expect(loadCount == 2)
        #expect(assistantTexts(in: pane.liveStore.state.timeline) == ["recovered reply"])
        #expect(pane.liveStore.state.timeline.turns.map(\.runID) == ["recover-run"])
    }

    @Test("detached recovery retry resumes a persisted streaming Part for later deltas")
    func detachedRecoveryRetryResumesPersistedPart() async throws {
        let router = RunEventRouter()
        var loadCount = 0
        var persistedText = ""
        let conversationID = "detached-recovery-conversation"
        let runID = "detached-recovery-run"
        let messageID = "detached-recovery-message"
        let partID = "detached-recovery-part"

        func makeRecoveryPane() throws -> ConversationPaneController {
            try makePane(conversationID: conversationID) { id -> ConversationTimelineProjection in
                loadCount += 1
                if loadCount == 1 { throw RouterLoadFailure.unavailable }
                return self.persistedTimeline(
                    conversationID: id,
                    runID: runID,
                    messageID: messageID,
                    partID: partID,
                    assistantText: persistedText
                )
            }
        }

        let firstPane = try makeRecoveryPane()
        #expect(router.registerPane(firstPane))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(
            runID: runID,
            messageID: messageID,
            partID: partID,
            kind: .text
        ))
        persistedText = "hello"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "hello", endUTF8Offset: 5))
        router.unregisterPane(for: conversationID)

        let reopenedPane = try makeRecoveryPane()
        #expect(router.registerPane(reopenedPane))
        persistedText = "hello world"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: " world", endUTF8Offset: 11))
        #expect(await router.retryTimelineLoad(for: conversationID))
        #expect(assistantTexts(in: reopenedPane.liveStore.state.timeline) == ["hello world"])
        #expect(reopenedPane.liveStore.state.activeParts[partID]?.text == "hello world")

        persistedText = "hello world!"
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "!", endUTF8Offset: 12))
        await router.handle(.messagePartCompleted(runID: runID, partID: partID, state: .completed))
        await router.handle(.runEnded(runID: runID, state: .completed, endReason: .completed))

        #expect(assistantTexts(in: reopenedPane.liveStore.state.timeline) == ["hello world!"])
        #expect(reopenedPane.liveStore.droppedUnlocatableDeltas == 0)
        #expect(reopenedPane.liveStore.state.activeParts.isEmpty)
    }

    @Test("a terminal hidden Run releases its Pane before the next persisted open")
    func terminalHiddenRunReopensFromPersistedTimeline() async throws {
        let router = RunEventRouter()
        let conversationID = "terminal-remount-conversation"
        let runID = "terminal-remount-run"
        let messageID = "terminal-remount-message"
        let partID = "terminal-remount-part"
        let firstPane = try makePane(conversationID: conversationID) { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: runID, items: [.userText("prompt")])]
            )
        }
        #expect(router.registerPane(firstPane))
        await router.handle(.runAccepted(runID: runID, conversationID: conversationID))
        await router.handle(.messagePartStarted(
            runID: runID,
            messageID: messageID,
            partID: partID,
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: runID, partID: partID, delta: "live answer", endUTF8Offset: 11))
        router.unregisterPane(for: conversationID)
        await router.handle(.messagePartCompleted(runID: runID, partID: partID, state: .completed))
        await router.handle(.runEnded(runID: runID, state: .completed, endReason: .completed))

        let persisted = ConversationTimelineProjection(
            conversationID: conversationID,
            turns: [ConversationTurn(
                runID: runID,
                items: [.userText("prompt"), .assistantText("persisted answer")],
                textSourcesByItemIndex: [1: TimelineTextSource(
                    conversationID: conversationID,
                    messageID: messageID,
                    partID: partID,
                    isCompleted: true
                )]
            )]
        )
        let reopenedPane = try makePane(conversationID: conversationID) { _ in persisted }
        try reopenedPane.reloadTimeline()
        #expect(router.registerPane(reopenedPane))

        #expect(assistantTexts(in: reopenedPane.liveStore.state.timeline) == ["persisted answer"])
        #expect(reopenedPane.liveStore.state.timeline.turns[0].textSourcesByItemIndex[1]?.isCompleted == true)
        #expect(reopenedPane.liveStore.state.activeParts.isEmpty)
        #expect(router.recoveryMessage(for: conversationID) == nil)
    }

    @Test("detached Run events remain scoped to their owning Conversation")
    func detachedRunEventsStayConversationScoped() async throws {
        let router = RunEventRouter()
        let paneA = try makePane(conversationID: "detached-A") { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "detached-run-A", items: [.userText("prompt")])]
            )
        }
        let paneB = try makePane(conversationID: "detached-B") { id in
            ConversationTimelineProjection(conversationID: id, turns: [])
        }
        #expect(router.registerPane(paneA))
        #expect(router.registerPane(paneB))
        await router.handle(.runAccepted(runID: "detached-run-A", conversationID: "detached-A"))
        await router.handle(.messagePartStarted(
            runID: "detached-run-A",
            messageID: "detached-message-A",
            partID: "detached-part-A",
            kind: .text
        ))
        await router.handle(.messagePartDelta(runID: "detached-run-A", partID: "detached-part-A", delta: "A", endUTF8Offset: 1))
        router.unregisterPane(for: "detached-A")
        await router.handle(.messagePartDelta(runID: "detached-run-A", partID: "detached-part-A", delta: " hidden", endUTF8Offset: 8))

        #expect(assistantTexts(in: paneB.liveStore.state.timeline).isEmpty)

        let reopenedPaneA = try makePane(conversationID: "detached-A") { id in
            self.persistedTimeline(
                conversationID: id,
                runID: "detached-run-A",
                messageID: "detached-message-A",
                partID: "detached-part-A",
                assistantText: "A hidden"
            )
        }
        #expect(router.registerPane(reopenedPaneA))
        #expect(assistantTexts(in: reopenedPaneA.liveStore.state.timeline) == ["A hidden"])
        #expect(assistantTexts(in: paneB.liveStore.state.timeline).isEmpty)
    }

    @Test("unregisteredRunEventsAreDroppedWithoutPaneMutation")
    func unregisteredRunEventsAreDroppedWithoutPaneMutation() async throws {
        let router = RunEventRouter()
        let pane = try makePane(conversationID: "known-pane") { id in
            ConversationTimelineProjection(
                conversationID: id,
                turns: [ConversationTurn(runID: "unknown-run", items: [.userText("keep")])]
            )
        }
        #expect(router.registerPane(pane))
        let before = pane.liveStore.state

        await router.handle(.messagePartStarted(
            runID: "unknown-run",
            messageID: "unknown-message",
            partID: "unknown-part",
            kind: .text
        ))

        #expect(pane.liveStore.state == before)
        #expect(router.diagnostics.contains("Dropped unregistered Run event for unknown-run"))
    }

    @Test("sendPreparationFailureIsVisibleAndKeepsDraft")
    func sendPreparationFailureIsVisibleAndKeepsDraft() async throws {
        let instanceID = ProviderInstanceID(rawValue: "composer-error-instance")
        let modelID = Stage2GateFixture.modelID
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: instanceID,
            displayName: "Test model",
            capabilities: [.text, .streaming]
        )
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in throw ComposerSendFailure.keychainUnavailable },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in nil },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: "keep this draft",
                selection: ComposerSelection(range: 0..<15),
                references: [],
                attachments: [],
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "composer-error-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(coordinator.sendErrorMessage == "Keychain 不可用")
        #expect(coordinator.submission == .idle)
        #expect(controller.draft.text == "keep this draft")
    }

    @Test("committedSendFailureKeepsTheDurableTurnAndClearsTheDraft")
    func committedSendFailureKeepsTheDurableTurnAndClearsTheDraft() async throws {
        let instanceID = ProviderInstanceID(rawValue: "committed-error-instance")
        let modelID = Stage2GateFixture.modelID
        let descriptor = ModelDescriptor(
            id: modelID,
            providerInstanceID: instanceID,
            displayName: "Test model",
            capabilities: [.text, .streaming]
        )
        let bridge = ComposerRuntimeActionBridge(
            start: { _ in throw ComposerSendFailure.committed(runID: "durable-run") },
            stop: { _ in },
            models: { _ in [descriptor] },
            projection: { _ in RunProjection(runID: "durable-run", state: .failed) },
            projectionUpdates: { _ in AsyncStream { $0.yield(nil) } }
        )
        let configuration = ConversationComposerConfiguration(
            providerInstanceID: instanceID,
            modelID: modelID
        )
        let controller = ComposerController(
            draft: ComposerDraftState(
                text: "already saved",
                selection: ComposerSelection(range: 0..<14),
                references: [],
                attachments: [],
                presentationState: .resting
            ),
            configuration: configuration
        )
        let coordinator = ComposerSendCoordinator(
            conversationID: "committed-error-conversation",
            controller: controller,
            configuration: configuration,
            bridge: bridge,
            maxProviderSteps: 4
        )

        _ = await coordinator.handlePrimaryAction(at: Date())

        #expect(controller.draft.text.isEmpty)
        #expect(coordinator.submission == .idle)
        #expect(coordinator.sendErrorMessage == "消息已保存，但运行未能完成。")
    }

    @Test("App Space explicit New becomes durable before Full and preserves the original warm owner on cancellation")
    func explicitAppSpaceNewPreservesOrigin() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let originalID = fixture.model.conversationID
        let original = try #require(fixture.model.pane?.session)
        original.composer.draft.text = "original draft"
        #expect(fixture.model.enterPreview())
        let requests = fixture.model.router.historyPreparation.requested
        let newWindow = try fixture.model.newConversationBrowseWindow()
        #expect(newWindow.older.first?.id == originalID)
        #expect(fixture.model.router.historyPreparation.requested == requests)
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(created != originalID)
        #expect(try fixture.store.conversation(id: created)?.lifecycle == .visible)
        #expect(fixture.model.conversationID == originalID && fixture.model.pane == nil)
        #expect(fixture.model.previewContent.session === original)
        #expect(await fixture.model.preparePreviewReturn(to: created))
        #expect(fixture.model.previewContent.prepared?.pane.composer.configuration?.modelID == fixture.modelID)
        fixture.model.cancelPreviewReturn()
        #expect(fixture.model.previewContent.session === original && fixture.model.pane == nil)
        #expect(original.composer.draft.text == "original draft")
        #expect(await fixture.model.preparePreviewReturn(to: created))
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == created)
        #expect(fixture.model.pane?.composer.draft.presentationState == .resting)
        #expect(fixture.model.pane?.composer.draft.text == "")
        #expect(fixture.model.canSend)
        #expect(try fixture.store.activeParentRunIDs().isEmpty)
        #expect(fixture.model.renameAppSpaceConversation(id: created, title: "created manual") == false)
        // Same-process retained drafts must remain navigable after successful New.
        #expect(await fixture.model.openConversation(id: originalID))
        #expect(fixture.model.pane?.session === original)
        // Missing original is a warm owner, not a newly fabricated persisted row.
        #expect(try fixture.store.conversation(id: originalID) == nil)
    }

    @Test("a retained unsent draft remains reachable by Card after New commits")
    func unsentDraftRemainsNavigableAfterNew() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = fixture.model.conversationID
        let original = try #require(fixture.model.pane?.session)
        original.composer.draft.text = "未发送的草稿 🧑🏽‍💻"
        #expect(fixture.model.enterPreview())
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(await fixture.model.preparePreviewReturn(to: created))
        #expect(fixture.model.commitPreviewReturn())
        let newOwner = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        let reads = fixture.model.router.historyPreparation.requested
        let window = try fixture.model.newConversationBrowseWindow()
        #expect(window.summaries.contains { $0.id == id })
        #expect(window.summaries.count <= 3)
        let warmWindow = try fixture.model.browseWindow(id: id)
        #expect(warmWindow.current?.id == id)
        #expect(warmWindow.summaries.count <= 5)
        #expect(fixture.model.router.historyPreparation.requested == reads)
        let ready = await fixture.model.preparePreviewReturn(to: id)
        #expect(ready)
        guard ready else { return }
        #expect(fixture.model.conversationID == created && fixture.model.previewContent.session === newOwner)
        #expect(fixture.model.previewContent.prepared?.pane.session === original)
        #expect(fixture.model.commitPreviewReturn())
        #expect(fixture.model.pane?.session === original)
        #expect(original.composer.draft.text == "未发送的草稿 🧑🏽‍💻")
        #expect(try fixture.store.conversation(id: id) == nil)
        #expect(try fixture.store.activeParentRunIDs().isEmpty)
    }

    @Test("retained draft ownership cannot remount a deleted ID or fabricate an unknown ID")
    func retainedDraftStillRejectsDeletedAndUnknown() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let id = fixture.model.conversationID
        let original = try #require(fixture.model.pane?.session)
        original.composer.draft.text = "protected draft"
        #expect(fixture.model.enterPreview())
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(await fixture.model.preparePreviewReturn(to: created))
        #expect(fixture.model.commitPreviewReturn())
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: id, lifecycle: .pendingDeletion).insert(db)
        }
        #expect(fixture.model.enterPreview())
        #expect(!(await fixture.model.preparePreviewReturn(to: id)))
        #expect(!(await fixture.model.preparePreviewReturn(to: "unknown-retained-draft")))
        #expect(!fixture.model.commitPreviewReturn())
        #expect(fixture.model.conversationID == created && fixture.model.pane == nil)
        #expect(original.composer.draft.text == "protected draft")
        #expect(try fixture.store.conversation(id: id)?.lifecycle == .pendingDeletion)
        #expect(try fixture.store.conversation(id: "unknown-retained-draft") == nil)
    }

    @Test("explicit empty history keeps its copied model binding before its first Send")
    func emptyDurableHistoryCanSend() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.createEmptyConversation(id: "empty-history", at: Fixtures.epoch, initialBinding: .init(providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        #expect(await fixture.model.openConversation(id: "empty-history"))
        #expect(fixture.model.pane?.composer.configuration?.modelID == fixture.modelID)
        #expect(fixture.model.canSend)
        #expect(fixture.model.persistedTurnCount == 0)
        try fixture.store.renameConversation(id: "empty-history", title: "manual before actual Send", at: Fixtures.epoch)
        try await send("first real turn", at: Fixtures.epoch.addingTimeInterval(10), in: fixture)
        #expect(fixture.model.persistedTurnCount == 1)
        #expect(try fixture.store.conversation(id: "empty-history")?.title == "manual before actual Send")
    }

    @Test("selected metadata edits neither prepare history nor replace the retained Session")
    func selectedMetadataDoesNotOpenFull() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "metadata-origin").insert(db)
            try Fixtures.conversation(id: "metadata-selected").insert(db)
        }
        #expect(await fixture.model.openConversation(id: "metadata-origin"))
        let original = try #require(fixture.model.pane?.session)
        #expect(fixture.model.enterPreview())
        let requests = fixture.model.router.historyPreparation.requested
        #expect(fixture.model.renameAppSpaceConversation(id: "metadata-selected", title: "Selected manual"))
        #expect(fixture.model.pinAppSpaceConversation(id: "metadata-selected", pinned: true))
        #expect(try fixture.store.conversation(id: "metadata-selected")?.title == "Selected manual")
        #expect(try fixture.store.conversation(id: "metadata-selected")?.pinned == true)
        #expect(try fixture.store.conversation(id: "metadata-selected")?.userActiveAt == Fixtures.epoch)
        #expect(fixture.model.previewContent.session === original && fixture.model.pane == nil)
        #expect(fixture.model.router.historyPreparation.requested == requests)
    }

    @Test("configured empty histories remain evictable after repeated selected Returns")
    func emptyConfiguredHistoryDoesNotPinColdSessions() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        for index in 0..<15 {
            try fixture.store.createEmptyConversation(id: "empty-lru-\(index)", at: Fixtures.epoch,
                initialBinding: .init(providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        }
        #expect(await fixture.model.openConversation(id: "empty-lru-0"))
        #expect(fixture.model.canSend)
        weak var cold = fixture.model.pane?.session
        for index in 1..<15 {
            #expect(fixture.model.enterPreview())
            #expect(await fixture.model.preparePreviewReturn(to: "empty-lru-\(index)"))
            #expect(fixture.model.commitPreviewReturn())
        }
        #expect(cold == nil)
    }

    @Test("New copied binding survives a cold reopen after the global default changes")
    func explicitNewBindingSurvivesGlobalChange() async throws {
        let fixture = try makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        #expect(fixture.model.enterPreview())
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(try fixture.store.conversationInitialBinding(id: created) == ConversationInitialBinding(providerInstanceID: fixture.instanceID, modelID: fixture.modelID))
        fixture.defaults.set("unavailable-new-global-instance", forKey: AppShellModel.defaultInstanceIDKey)
        let reopened = await makeReconstructedModel(from: fixture)
        #expect(await reopened.openConversation(id: created))
        #expect(reopened.pane?.composer.configuration?.providerInstanceID == fixture.instanceID)
        #expect(reopened.pane?.composer.configuration?.modelID == fixture.modelID)
        #expect(reopened.canSend)
    }

    @Test("New created without a binding does not silently follow a later global choice")
    func explicitlyUnconfiguredNewRemainsUnconfigured() async throws {
        let fixture = try makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        #expect(fixture.model.enterPreview())
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        fixture.defaults.set(fixture.instanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
        fixture.defaults.set(fixture.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
        let reopened = await makeReconstructedModel(from: fixture)
        #expect(await reopened.openConversation(id: created))
        #expect(reopened.pane?.composer.configuration == nil)
        #expect(!reopened.canSend)
    }

    @Test("the existing explicit configure action can initialize an unconfigured New without changing activity")
    func unconfiguredNewCanBeExplicitlyConfigured() async throws {
        let fixture = try makeFixture(seed: .active, setDefault: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        #expect(fixture.model.enterPreview())
        let created = try fixture.model.createConversationFromAppSpace(at: Fixtures.epoch)
        #expect(await fixture.model.preparePreviewReturn(to: created))
        #expect(fixture.model.commitPreviewReturn())
        #expect(!fixture.model.canSend)
        let setup = try #require(fixture.model.providerSetup)
        setup.apiKey = "explicit-new-fake-test-key"
        setup.selectedModelID = fixture.modelID
        #expect(setup.save())
        #expect(fixture.model.canSend)
        #expect(try fixture.store.conversationInitialBinding(id: created)?.providerInstanceID == setup.instanceID)
        #expect(try fixture.store.conversation(id: created)?.userActiveAt == Fixtures.epoch)
    }

    private func makeFixture(
        seed: ShellCredentialSeed,
        createInstance: Bool = true,
        setDefault: Bool = true,
        scripts: [Stage2ProviderScript] = [.events([])],
        store suppliedStore: PersistenceStore? = nil
    ) throws -> ShellFixture {
        let store = try suppliedStore ?? PersistenceStore(database: ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let metadata = InMemoryCredentialMetadataRepository()
        let credentials = CredentialStore(secrets: backend, metadataRepository: metadata)
        let instanceID = ProviderInstanceID(rawValue: "shell-instance-\(UUID().uuidString)")
        let reference = CredentialReference(
            id: "shell-reference-\(UUID().uuidString)",
            kind: .apiKey
        )
        let secret = "shell-test-key-\(UUID().uuidString)"

        if createInstance {
            try store.createProviderInstance(ProviderInstance(
                id: instanceID,
                providerID: .deepSeek,
                displayName: "DeepSeek",
                baseURL: nil,
                configRevision: .initial,
                credentialReference: reference
            ))
        }
        switch seed {
        case .none:
            break
        case .active:
            try credentials.provision(SecretValue(secret), as: reference)
        case .missingSecret:
            try metadata.saveMetadata(CredentialMetadata(
                reference: reference,
                bindingGeneration: 1,
                principalFingerprint: nil,
                status: .active,
                updatedAt: Date()
            ))
        case .unreadableSecret:
            try credentials.provision(SecretValue(secret), as: reference)
            backend.unreadableReferences = [reference.id]
        }

        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: scripts
        )
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: store,
            credentials: credentials,
            provider: provider,
            runtime: runtime,
            router: router
        )
        let suite = "ZenAgentTests.AppShell.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if setDefault {
            defaults.set(instanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
            defaults.set(Stage2GateFixture.modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
        }
        let model = AppShellModel(dependencies: dependencies, userDefaults: defaults)
        return ShellFixture(
            store: store,
            credentials: credentials,
            backend: backend,
            metadata: metadata,
            provider: provider,
            runtime: runtime,
            instanceID: instanceID,
            modelID: Stage2GateFixture.modelID,
            reference: reference,
            secret: secret,
            defaults: defaults,
            defaultsSuite: suite,
            model: model
        )
    }

    private func send(
        _ text: String,
        at timestamp: Date,
        in fixture: ShellFixture
    ) async throws {
        let pane = try #require(fixture.model.pane)
        let bridge = try #require(fixture.model.actionBridge)
        pane.composer.draft.text = text
        pane.composer.draft.selection = ComposerSelection(range: 0..<text.count)
        let command = try #require(ComposerSendCoordinator(
            conversationID: fixture.model.conversationID,
            controller: pane.composer,
            configuration: pane.composer.configuration,
            bridge: bridge,
            maxProviderSteps: AppShellModel.maxProviderSteps
        ).beginSend(
            capabilities: [.text, .streaming],
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: "recent-entry-\(UUID().uuidString)"
        ))

        let runID = try await ComposerSendTiming.$initiatedAt.withValue(timestamp) {
            try await bridge.start(command)
        }
        try await fixture.runtime.waitForCompletion(runID: runID)
    }

    private func makeReconstructedModel(from fixture: ShellFixture) async -> AppShellModel {
        let router = RunEventRouter()
        let runtime = AppAssembly.makeRuntime(
            store: fixture.store,
            provider: fixture.provider,
            credentials: fixture.credentials,
            router: router,
            toolRegistry: .empty
        )
        let dependencies = AppAssembly.Dependencies(
            store: fixture.store,
            credentials: fixture.credentials,
            provider: fixture.provider,
            runtime: runtime,
            router: router
        )
        let model = AppShellModel(dependencies: dependencies, userDefaults: fixture.defaults)
        await model.launchRestorationTask?.value
        return model
    }

    private func makePane(
        conversationID: String,
        loadTimeline: @escaping @MainActor (String) throws -> ConversationTimelineProjection
    ) throws -> ConversationPaneController {
        try ConversationPaneController(
            conversationID: conversationID,
            initialTimeline: ConversationTimelineProjection(conversationID: conversationID, turns: []),
            configuration: ConversationComposerConfiguration(
                providerInstanceID: ProviderInstanceID(rawValue: "router-instance"),
                modelID: Stage2GateFixture.modelID
            ),
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: loadTimeline
        )
    }

    private func persistedTimeline(
        conversationID: String,
        runID: String,
        messageID: String,
        partID: String,
        assistantText: String
    ) -> ConversationTimelineProjection {
        ConversationTimelineProjection(
            conversationID: conversationID,
            turns: [ConversationTurn(
                runID: runID,
                items: [.userText("prompt"), .assistantText(assistantText)],
                textSourcesByItemIndex: [1: TimelineTextSource(
                    conversationID: conversationID,
                    messageID: messageID,
                    partID: partID,
                    isCompleted: false
                )]
            )]
        )
    }

    private func assistantTexts(in timeline: ConversationTimelineProjection) -> [String] {
        timeline.turns.flatMap { turn in
            turn.items.compactMap { item in
                guard case let .assistantText(text) = item else { return nil }
                return text
            }
        }
    }

    private func conversationCount(in store: PersistenceStore) throws -> Int {
        try store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
        }
    }
}

private struct ShellFixture {
    let store: PersistenceStore
    let credentials: CredentialStore
    let backend: InMemorySecretBackend
    let metadata: InMemoryCredentialMetadataRepository
    let provider: Stage2ScriptedProvider
    let runtime: ConversationRuntime
    let instanceID: ProviderInstanceID
    let modelID: ModelID
    let reference: CredentialReference
    let secret: String
    let defaults: UserDefaults
    let defaultsSuite: String
    let model: AppShellModel
}

// GRDB invokes on its connection queue; the test reads on its own executor.
final class S504SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var summaryCount = 0
    var selectCount: Int { lock.withLock { count } }
    var summaryQueryCount: Int { lock.withLock { summaryCount } }
    func record(_ sql: String) {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.hasPrefix("SELECT") || normalized.hasPrefix("WITH") {
            lock.withLock {
                count += 1
                if normalized.hasPrefix("WITH PAGE AS MATERIALIZED") { summaryCount += 1 }
            }
        }
    }
}


private final class HistoryReadRounds: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var count = 0
    private var expired = false
    var entered: Int { lock.withLock { count } }
    var timedOut: Bool { lock.withLock { expired } }
    func blockNext() {
        let round = lock.withLock { count += 1; return count }
        if round <= 3, resume.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { expired = true }
        }
    }
    func release() { resume.signal() }
}

private final class PreviewReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var blocked = false
    private var expired = false
    var hasBlocked: Bool { lock.withLock { blocked } }
    var timedOut: Bool { lock.withLock { expired } }
    func blockOnce() {
        let first = lock.withLock {
            if blocked { return false }
            blocked = true
            return true
        }
        if first, resume.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { expired = true }
        }
    }
    func release() { resume.signal() }
}
private actor PreviewSubmissionGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func enter(_ command: SendCommand) async -> Int {
        count += 1
        let ordinal = count
        if ordinal == 1, !released { await withCheckedContinuation { continuation = $0 } }
        return ordinal
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor PreviewCommitGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        hasEntered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
