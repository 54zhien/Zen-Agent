import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **what the store was told to persist is what survives a restart,
/// and a terminal flush makes the content trustworthy.**
///
/// Scope note, because it is easy to overreach here: the coalescing window — how often
/// the Runtime calls `appendText` — is the Runtime's decision and is not tested here.
/// The persistence question is narrower and answerable: given a chunk, is it durable,
/// and can a reader tell a finished message from one that is still arriving?
///
/// **No timing thresholds.** A test that asserts "1000 deltas in under X ms" is a
/// flaky test on a shared CI runner, and the Stage 0 spike already measured the
/// throughput question properly. Performance belongs to real profiling in Stage 12,
/// not to a correctness suite that has to stay green on every commit.
@Suite("Streaming persistence")
struct StreamingPersistenceTests {

    private func seededStreamingStore(at url: URL) throws -> PersistenceStore {
        let store = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "m1", runID: "r1")
        )
        try store.createPart(Fixtures.streamingPart(id: "part1", messageID: "m1"))
        return store
    }

    @Test("appended text is durable")
    func appendedTextIsDurable() throws {
        let url = try Fixtures.scratchPath(name: "stream.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let store = try seededStreamingStore(at: url)
            try store.appendText(toPart: "part1", delta: "Hello")
            try store.appendText(toPart: "part1", delta: ", world")
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        #expect(
            try reopened.text(ofPart: "part1") == "Hello, world",
            "every appended chunk must be durable, in order and without loss"
        )
    }

    @Test("many appends accumulate without loss or duplication")
    func manyAppendsAccumulate() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.createPart(Fixtures.streamingPart(id: "part1", messageID: "m1"))

        let chunks = (1...50).map { "\($0);" }
        for chunk in chunks {
            try store.appendText(toPart: "part1", delta: chunk)
        }

        #expect(
            try store.text(ofPart: "part1") == chunks.joined(),
            "the accumulated text must be exactly the chunks in order — a repeated or dropped chunk shows up here"
        )
    }

    @Test("a terminal flush is durable and marks the content settled")
    func terminalFlushIsDurable() throws {
        let url = try Fixtures.scratchPath(name: "stream-flush.sqlite")
        defer { Fixtures.cleanUp(url) }

        do {
            let store = try seededStreamingStore(at: url)
            try store.appendText(toPart: "part1", delta: "Partial")
            // The run reaches a terminal state, so the part is closed.
            try store.finishPart(id: "part1", state: .completed)
        }

        let reopened = PersistenceStore(database: try ZenDatabase.open(at: url.path()))
        let part = try reopened.part(id: "part1")
        #expect(
            part?.state == .completed,
            """
            a part left in `.streaming` after the run ended is content nobody can tell is \
            complete — which is why the terminal flush exists
            """
        )
        #expect(try reopened.text(ofPart: "part1") == "Partial", "the flushed content must survive")
    }

    @Test("a part is not finalised into a still-open state")
    func finishRefusesOpenStates() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.createPart(Fixtures.streamingPart(id: "part1", messageID: "m1"))

        for open in [MessagePartState.streaming, .pending] {
            var failure: Error?
            do {
                try store.finishPart(id: "part1", state: open)
            } catch {
                failure = error
            }
            #expect(
                failure != nil,
                "finishing into \(open.rawValue) must be refused — it is the state the part is already in, not a conclusion"
            )
        }
    }

    @Test("no part is left streaming once the run reaches a terminal state")
    func terminalRunLeavesNoStreamingPart() throws {
        let url = try Fixtures.scratchPath(name: "stream-terminal.sqlite")
        defer { Fixtures.cleanUp(url) }

        let store = try seededStreamingStore(at: url)
        try store.appendText(toPart: "part1", delta: "done")
        try store.finishPart(id: "part1", state: .completed)
        try store.finishRun(id: "r1", state: .completed, endReason: .completed)

        let parts = try store.parts(ofMessage: "m1")
        #expect(
            parts.allSatisfy { $0.state != .streaming && $0.state != .pending },
            """
            a run that has ended must not leave a part the UI would keep showing as \
            in-progress — the same invariant the Runtime has to uphold, checked here at \
            the layer that would be left holding the inconsistency
            """
        )
    }

    @Test("finishing a part that does not exist is refused")
    func finishingUnknownPartIsRefused() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())

        var failure: Error?
        do {
            try store.finishPart(id: "typo", state: .completed)
        } catch {
            failure = error
        }

        // `partNotFound` exists but is never thrown here — today the update touches
        // no row and reports success.
        #expect(
            failure as? ZenAgent.PersistenceError == .partNotFound("typo"),
            "finishing a part that is not on disk must not report success; got \(String(describing: failure))"
        )
    }

    @Test("a part that is already settled must not be finished again")
    func settledPartCannotBeFinishedAgain() throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.commitUserTurnAndCreateParentRun(Fixtures.send(messageID: "m1", runID: "r1"))
        try store.createPart(Fixtures.streamingPart(id: "part1", messageID: "m1"))
        try store.finishPart(id: "part1", state: .completed)

        var failure: Error?
        do {
            try store.finishPart(id: "part1", state: .failed)
        } catch {
            failure = error
        }

        guard
            let failure = failure as? ZenAgent.PersistenceError,
            case .invalidTransition = failure
        else {
            Issue.record("expected invalidTransition, got \(String(describing: failure))")
            return
        }
        #expect(
            try store.part(id: "part1")?.state == .completed,
            "a refused re-finish must leave the recorded outcome in place"
        )
    }
}
