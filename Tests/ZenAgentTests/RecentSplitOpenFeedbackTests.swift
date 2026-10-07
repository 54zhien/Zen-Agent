import Foundation
import GRDB
import Testing
@testable import ZenAgent

@Suite("Recent occupied Split open feedback")
@MainActor
struct RecentSplitOpenFeedbackTests {
    @Test("occupied secondary failure preserves both owners and retries the same target")
    func occupiedSecondaryRecentOpenFailureKeepsPaneAndTargetsRetry() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "recent-secondary-B").insert(db)
        }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "recent-target-C", messageID: "recent-C-user", runID: "recent-C-run", runState: .completed))
        let model = fixture.model
        let source = try #require(model.pane)
        #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
        #expect(await model.openInSplit(id: "recent-secondary-B"))
        let secondary = try #require(model.splitPane)
        secondary.composer.draft.text = "B retained draft"
        secondary.composer.draft.selection = ComposerSelection(range: 2..<5)
        let arrangement = try #require(model.splitWorkspace)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                arguments: ["invalid-recent-C-state", "recent-C-run"])
        }
        model.refreshRecentConversations()
        #expect(model.recentConversations.contains { $0.id == "recent-target-C" })
        let failure = await model.openInSplitResult(id: "recent-target-C")
        #expect(failure == .failed(RecentConversationOpenFailure(conversationID: "recent-target-C")))
        #expect(model.splitOpenRetryID == "recent-target-C")
        #expect(model.recentListingError == nil)
        #expect(model.pane === source)
        #expect(model.splitPane === secondary)
        #expect(model.splitPane?.session === secondary.session)
        #expect(secondary.composer.draft.text == "B retained draft")
        #expect(secondary.composer.draft.selection == ComposerSelection(range: 2..<5))
        #expect(model.splitWorkspace == arrangement)
        try fixture.store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                arguments: [RunState.completed.rawValue, "recent-C-run"])
        }
        #expect(await model.openInSplitResult(id: "recent-target-C") == .opened(conversationID: "recent-target-C"))
        #expect(model.splitOpenRetryID == nil)
        #expect(model.splitPane?.conversationID == "recent-target-C")
        #expect(model.pane === source)
        #expect(secondary.composer.draft.text == "B retained draft")
    }

    @Test("obsolete reads are quiet and never overwrite the newer owner or feedback",
          arguments: [false, true], RecentReadInterruption.allCases)
    func obsoleteRecentReadIsQuiet(primary: Bool, interruption: RecentReadInterruption) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: interruption != .arrangement)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let source = try #require(model.pane)
        let secondary = try #require(model.splitPane)
        let arrangement = try #require(model.splitWorkspace?.arrangementID)
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let requests = model.router.historyPreparation.requested
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        try await requireBlocked(gate)
        var newer: Task<ConversationOpenOutcome, Never>?
        switch interruption {
        case .cancel:
            opening.cancel()
        case .newSelection:
            newer = Task {
                primary ? await model.openConversationResult(id: "recent-target-D")
                    : await model.openInSplitResult(id: "recent-target-D")
            }
            for _ in 0..<200 where model.router.historyPreparation.requested < requests + 2 {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try #require(model.router.historyPreparation.requested == requests + 2)
        case .arrangement, .lateError:
            // Release SQL before synchronous close reads metadata. This actor
            // cannot resume the opener until the new arrangement is installed.
            gate.release()
            model.closeSplit()
            #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
            #expect(model.splitWorkspace?.arrangementID != arrangement)
        case .lostTicket:
            model.router.cancelPanePreparation(for: "recent-target-C")
        }
        gate.release()
        #expect(await opening.value == .cancelled(conversationID: "recent-target-C"))
        if let newer {
            #expect(await newer.value == .opened(conversationID: "recent-target-D"))
            #expect(primary ? model.pane?.conversationID == "recent-target-D"
                : model.splitPane?.conversationID == "recent-target-D")
        } else {
            #expect(model.pane === source)
            if interruption == .arrangement || interruption == .lateError {
                #expect(model.splitPane == nil)
            } else {
                #expect(model.splitPane === secondary)
            }
        }
        #expect(secondary.composer.draft.text == "B preserved feedback draft")
        #expect(model.recentOpenFailure == nil)
        #expect(model.splitOpenError == nil)
        #expect(model.splitOpenRetryID == nil)
    }

    @Test("a new Split invalidates a pending Single open including its late read error", arguments: [false, true])
    func singleToSplitInvalidatesOpen(corrupt: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: corrupt)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        model.closeSplit()
        let source = try #require(model.pane)
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task { await model.openConversationResult(id: "recent-target-C") }
        try await requireBlocked(gate)
        gate.release()
        #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
        #expect(await opening.value == .cancelled(conversationID: "recent-target-C"))
        #expect(model.pane === source)
        #expect(model.splitPane == nil)
        #expect(model.recentOpenFailure == nil)
    }

    @Test("choosing the already displayed owner supersedes a pending target open", arguments: [false, true])
    func cachedChoiceSupersedesPendingOpen(primary: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let source = try #require(model.pane)
        let secondary = try #require(model.splitPane)
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        try await requireBlocked(gate)
        // Cached primary selection reads lifecycle synchronously, so release
        // the connection before this actor installs the newer operation identity.
        gate.release()
        let chosenID = primary ? source.conversationID : secondary.conversationID
        let chosen = primary ? await model.openConversationResult(id: chosenID)
            : await model.openInSplitResult(id: chosenID)
        #expect(chosen == .opened(conversationID: chosenID))
        #expect(await opening.value == .cancelled(conversationID: "recent-target-C"))
        #expect(model.pane === source && model.splitPane === secondary)
        #expect(model.recentOpenFailure == nil && model.splitOpenError == nil && model.splitOpenRetryID == nil)
    }

    @Test("same arrangement ratio updates survive a ready open", arguments: [false, true])
    func readyOpenPreservesLiveRatio(primary: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let arrangement = try #require(model.splitWorkspace?.arrangementID)
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        try await requireBlocked(gate)
        model.setSplitRatio(0.63)
        gate.release()
        #expect(await opening.value == .opened(conversationID: "recent-target-C"))
        #expect(model.splitWorkspace?.arrangementID == arrangement)
        #expect(model.splitWorkspace?.activeRatio == 0.63)
    }

    @Test("a cached choice through the other open route supersedes the old target", arguments: [false, true])
    func crossRouteCachedChoiceSupersedesOpen(primary: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let source = try #require(model.pane)
        let secondary = try #require(model.splitPane)
        let split = try #require(model.splitWorkspace)
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        try await requireBlocked(gate)
        gate.release()
        let chosenID = primary ? secondary.conversationID : source.conversationID
        let chosen = primary ? await model.openInSplitResult(id: chosenID)
            : await model.openConversationResult(id: chosenID)
        #expect(chosen == .opened(conversationID: chosenID))
        #expect(await opening.value == .cancelled(conversationID: "recent-target-C"))
        #expect(model.splitWorkspace?.activeSlot == (primary ? split.emptySlot : split.sourceSlot))
        #expect(model.pane === source && model.splitPane === secondary)
        #expect(secondary.composer.draft.text == "B preserved feedback draft")
        #expect(model.recentOpenFailure == nil && model.splitOpenError == nil && model.splitOpenRetryID == nil)
    }

    @Test("an already cancelled request does not supersede the current open", arguments: [false, true])
    func cancelledIncomingChoiceDoesNotDisturbOpen(primary: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let gate = try installReadGate(in: fixture.store)
        defer {
            gate.release()
            try? fixture.store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        try await requireBlocked(gate)
        let discarded = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return primary ? await model.openConversationResult(id: "recent-target-D")
                : await model.openInSplitResult(id: "recent-target-D")
        }
        #expect(await discarded.value == .cancelled(conversationID: "recent-target-D"))
        gate.release()
        #expect(await opening.value == .opened(conversationID: "recent-target-C"))
        #expect(primary ? model.pane?.conversationID == "recent-target-C"
            : model.splitPane?.conversationID == "recent-target-C")
    }

    @Test("target deleted after the visible snapshot cannot register a ghost Pane", arguments: [false, true])
    func targetDeletedAfterSnapshotIsFailed(primary: Bool) async throws {
        let path = try Fixtures.scratchPath(name: "recent-visibility.sqlite")
        defer { Fixtures.cleanUp(path) }
        try await checkDeletionAfterSnapshot(path: path, primary: primary)
    }

    private func checkDeletionAfterSnapshot(path: URL, primary: Bool) async throws {
        let store = PersistenceStore(database: try ZenDatabase.open(at: path.path))
        let writer = PersistenceStore(database: try ZenDatabase.open(at: path.path))
        let fixture = try await makeOccupiedFixture(corrupt: false, store: store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let source = try #require(model.pane)
        let secondary = try #require(model.splitPane)
        #expect(try writer.conversationLifecycle(id: "recent-target-C") == .visible)
        let gate = try installReadGate(in: store)
        defer {
            gate.release()
            try? store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        let opening = Task {
            primary ? await model.openConversationResult(id: "recent-target-C")
                : await model.openInSplitResult(id: "recent-target-C")
        }
        // The conversation SELECT precedes the blocked Run SELECT in the
        // reader's WAL snapshot. The independent writer changes current truth.
        try await requireBlocked(gate)
        try writer.database.write { db in
            try db.execute(sql: "UPDATE conversation SET lifecycle = ? WHERE id = ?",
                arguments: [ConversationLifecycle.pendingDeletion.rawValue, "recent-target-C"])
        }
        #expect(try writer.conversationLifecycle(id: "recent-target-C") == .pendingDeletion)
        gate.release()
        #expect(await opening.value == .failed(RecentConversationOpenFailure(conversationID: "recent-target-C")))
        #expect(model.pane === source && model.splitPane === secondary)
        #expect(secondary.composer.draft.text == "B preserved feedback draft")
    }

    @Test("Picker retry dispatches target open or failed page without mixing them", arguments: [false, true])
    func splitPickerRetryDispatchesItsFailure(paging: Bool) async throws {
        let fixture = try await makeOccupiedFixture(corrupt: !paging)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        model.closeSplit()
        #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
        if paging {
            try fixture.store.database.write { db in
                for index in 0..<101 { try Fixtures.conversation(id: "picker-page-\(index)").insert(db) }
            }
            model.refreshRecentConversations()
            #expect(model.recentConversations.count == 50)
            let requests = model.router.historyPreparation.requested
            try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE messagePart RENAME TO recent_failed_parts") }
            model.loadMoreRecentConversations()
            #expect(model.recentListingError != nil)
            #expect(model.splitOpenRetryID == nil)
            #expect(model.recentConversations.count == 50)
            try fixture.store.database.write { db in try db.execute(sql: "ALTER TABLE recent_failed_parts RENAME TO messagePart") }
            await model.retrySplitPicker()
            #expect(model.recentConversations.count == 100)
            #expect(model.recentListingError == nil)
            #expect(model.splitPane == nil)
            #expect(model.router.historyPreparation.requested == requests)
        } else {
            #expect(await model.openInSplitResult(id: "recent-target-C")
                == .failed(RecentConversationOpenFailure(conversationID: "recent-target-C")))
            #expect(model.splitOpenRetryID == "recent-target-C")
            try fixture.store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                    arguments: [RunState.completed.rawValue, "recent-C-run"])
            }
            await model.retrySplitPicker()
            #expect(model.splitPane?.conversationID == "recent-target-C")
            #expect(model.splitOpenError == nil && model.splitOpenRetryID == nil)
        }
    }

    private func makeOccupiedFixture(corrupt: Bool, store: PersistenceStore? = nil) async throws -> ShellFixture {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, store: store)
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "recent-source-A").insert(db)
            try Fixtures.conversation(id: "recent-secondary-B").insert(db)
            try Fixtures.conversation(id: "recent-target-D").insert(db)
        }
        try fixture.store.commitUserTurnAndCreateParentRun(Fixtures.send(
            conversationID: "recent-target-C", messageID: "recent-C-user", runID: "recent-C-run", runState: .completed))
        _ = try #require(await fixture.model.openConversation(id: "recent-source-A"))
        #expect(fixture.model.commitSplitDrop(SplitDropIntent(conversationID: fixture.model.conversationID, slot: .top)))
        _ = try #require(await fixture.model.openInSplit(id: "recent-secondary-B"))
        let secondary = try #require(fixture.model.splitPane)
        secondary.composer.draft.text = "B preserved feedback draft"
        if corrupt {
            try fixture.store.database.write { db in
                try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                    arguments: ["invalid-recent-C-state", "recent-C-run"])
            }
        }
        return fixture
    }

    private func installReadGate(in store: PersistenceStore) throws -> RecentHistoryReadGate {
        let gate = RecentHistoryReadGate()
        try store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        return gate
    }

    private func requireBlocked(_ gate: RecentHistoryReadGate) async throws {
        for _ in 0..<200 where !gate.hasBlocked { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(gate.hasBlocked, "real target history did not reach its read gate")
    }
}

enum RecentReadInterruption: CaseIterable, Equatable, Sendable {
    case cancel, newSelection, arrangement, lostTicket, lateError
}

private final class RecentHistoryReadGate: @unchecked Sendable {
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
        if first, resume.wait(timeout: .now() + 10) == .timedOut { lock.withLock { expired = true } }
    }
    func release() { resume.signal() }
}
