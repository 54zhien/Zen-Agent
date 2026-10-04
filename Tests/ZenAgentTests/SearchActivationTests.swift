import Foundation
import Testing
import GRDB
@testable import ZenAgent

@Suite("Search activation scope")
@MainActor
struct SearchActivationTests {
    @Test func warmResultCommitsRestingAndPreservesBothDrafts() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let shell = fixture.model
        let originID = shell.conversationID
        let origin = try #require(shell.pane?.session)
        origin.composer.draft.text = "outgoing unsent draft"
        try fixture.store.database.write { db in try Fixtures.conversation(id: "warm-search").insert(db) }
        #expect(await shell.openConversation(id: "warm-search"))
        let target = try #require(shell.pane?.session)
        target.composer.draft.text = "target draft"
        target.composer.draft.presentationState = .editing
        #expect(await shell.openConversation(id: originID))
        #expect(shell.pane?.session === origin)
        #expect(await shell.openConversation(id: "warm-search", presentation: .resting))
        #expect(shell.pane?.session === target)
        #expect(target.composer.draft.presentationState == .resting)
        #expect(target.composer.draft.text == "target draft")
        #expect(origin.composer.draft.text == "outgoing unsent draft")
        target.composer.draft.presentationState = .editing
        #expect(await shell.openConversation(id: "warm-search", presentation: .resting))
        #expect(target.composer.draft.presentationState == .resting)
    }

    @Test func hiddenResultCannotReplaceOrRestTheOutgoingOwner() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let origin = try #require(fixture.model.pane)
        origin.composer.draft.text = "keep editing"
        origin.composer.draft.presentationState = .editing
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "hidden-result", lifecycle: .pendingDeletion).insert(db)
        }
        #expect(await fixture.model.openConversation(id: "hidden-result", presentation: .resting) == false)
        #expect(fixture.model.pane === origin)
        #expect(origin.composer.draft.text == "keep editing")
        #expect(origin.composer.draft.presentationState == .editing)
    }

    @Test func deletionAfterHistorySnapshotCannotCommitAStaleResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "search.sqlite").path
        let store = PersistenceStore(database: try ZenDatabase.open(at: path))
        let writer = PersistenceStore(database: try ZenDatabase.open(at: path))
        let fixture = try AppShellWiringTests().makeFixture(seed: .active, store: store)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        await fixture.model.launchRestorationTask?.value
        let origin = try #require(fixture.model.pane)
        origin.composer.draft.text = "preserve origin"
        try store.database.write { db in try Fixtures.conversation(id: "stale-search").insert(db) }
        let gate = SearchHistoryGate()
        defer {
            gate.release()
            try? store.database.read { $0.trace(nil) }
            #expect(!gate.timedOut)
        }
        try store.database.read { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.lowercased().contains("agentrun") { gate.blockOnce() }
            }
        }
        let opening = Task { await fixture.model.openConversation(id: "stale-search", presentation: .resting) }
        guard await gate.waitForEntry() else {
            opening.cancel(); Issue.record("History did not reach its controlled snapshot gate"); return
        }
        // The second real WAL connection commits deletion while the original
        // read snapshot still contains the visible Conversation.
        try writer.beginDeletion(conversationID: "stale-search", at: Fixtures.epoch)
        gate.release()
        #expect(await opening.value == false)
        #expect(fixture.model.pane === origin)
        #expect(origin.composer.draft.text == "preserve origin")
    }
}

private final class SearchHistoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var expired = false
    private var waiter: CheckedContinuation<Bool, Never>?
    var timedOut: Bool { lock.withLock { expired } }
    func blockOnce() {
        let first = lock.withLock {
            guard !entered else { return false }
            entered = true; waiter?.resume(returning: true); waiter = nil
            return true
        }
        if first, semaphore.wait(timeout: .now() + 10) == .timedOut { lock.withLock { expired = true } }
    }
    func waitForEntry() async -> Bool {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            lock.withLock { waiter?.resume(returning: false); waiter = nil }
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            lock.withLock {
                if entered { continuation.resume(returning: true) } else { waiter = continuation }
            }
        }
    }
    func release() { semaphore.signal() }
}
