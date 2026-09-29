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

    @Test("durable deltas during every history read cannot starve Preview Return")
    func previewDeltasDuringHistoryRead() async throws {
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
            gate.release()
        }
        await operation.value
        #expect(result == true)
        #expect(fixture.model.commitPreviewReturn())
        let pane = try #require(fixture.model.pane)
        #expect(pane.session === session)
        try writer.finishPart(id: "read-part", state: .completed)
        await fixture.model.router.handle(.messagePartCompleted(runID: runID, partID: "read-part", state: .completed))
        #expect(pane.liveStore.state.timeline.turns.flatMap(\.items).contains(.assistantText(expected)))
        #expect(pane.liveStore.droppedUnlocatableDeltas == 0)
        #expect(!pane.liveStore.needsTimelineReload)
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
            if let card = view as? SurfaceClipView { return card }
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
        try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE failed_preview_message RENAME TO message") }
        #expect(await fixture.model.preparePreviewReturn())
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
    var entered: Int { lock.withLock { count } }
    func blockNext() {
        let round = lock.withLock { count += 1; return count }
        if round <= 3 { _ = resume.wait(timeout: .now() + 10) }
    }
    func release() { resume.signal() }
}

private final class PreviewReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var blocked = false
    var hasBlocked: Bool { lock.withLock { blocked } }
    func blockOnce() {
        let first = lock.withLock {
            if blocked { return false }
            blocked = true
            return true
        }
        if first { _ = resume.wait(timeout: .now() + 10) }
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
