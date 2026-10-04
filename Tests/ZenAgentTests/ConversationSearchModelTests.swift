import Foundation
import Testing
@testable import ZenAgent

@Suite("Search query publication")
@MainActor
struct ConversationSearchModelTests {
    @Test func lateReadCannotReplaceANewerQuery() async {
        let gate = SearchReadGate()
        let model = ConversationSearchModel(debounce: .zero) { query, _, _ in
            await gate.read(query)
        }
        model.query = "old"
        let old = Task { await model.refresh() }
        await gate.waitForRead("old")
        model.query = "new"
        let new = Task { await model.refresh() }
        await gate.waitForRead("new")
        await gate.finish("new", page: page("new"))
        await new.value
        #expect(model.items.map(\.id) == ["new"])
        await gate.finish("old", page: page("old"))
        await old.value
        #expect(model.items.map(\.id) == ["new"])
        #expect(!model.isLoading)
    }

    @Test func cancelledReadCannotPublishOrKeepLoading() async {
        let gate = SearchReadGate()
        let model = ConversationSearchModel(debounce: .zero) { query, _, _ in
            await gate.read(query)
        }
        model.query = "cancelled"
        let task = Task { await model.refresh() }
        await gate.waitForRead("cancelled")
        task.cancel()
        await gate.finish("cancelled", page: page("cancelled"))
        await task.value
        #expect(model.items.isEmpty)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    @Test func cancelledOldReadCannotClearTheNewQueriesLoadingState() async {
        let gate = SearchReadGate()
        let model = ConversationSearchModel(debounce: .zero) { query, _, _ in
            await gate.read(query)
        }
        model.query = "old"
        let old = Task { await model.refresh() }
        await gate.waitForRead("old")
        model.query = "new"
        let new = Task { await model.refresh() }
        await gate.waitForRead("new")
        old.cancel()
        await gate.finish("old", page: page("old"))
        await old.value
        #expect(model.isLoading)
        #expect(model.items.isEmpty)
        #expect(model.errorMessage == nil)
        await gate.finish("new", page: page("new"))
        await new.value
        #expect(!model.isLoading)
        #expect(model.items.map(\.id) == ["new"])
    }

    private func page(_ id: String) -> ConversationSummaryPage {
        ConversationSummaryPage(items: [ConversationSummary(id: id, title: id, excerpt: "",
            pinned: false, userActiveAt: .distantPast, contentUnavailable: false,
            runProjection: nil, providerInstanceID: nil, modelID: nil, providerName: nil)], nextCursor: nil)
    }

    @Test func queryReplacementCancelsAPendingSelection() async {
        let unused = page("unused")
        let model = ConversationSearchModel(debounce: .zero) { _, _, _ in unused }
        let gate = SearchSelectionGate()
        var successes = 0
        let pending = model.select("old-result", open: { _ in await gate.open() }, onSuccess: { successes += 1 })
        await gate.waitForOpen()
        model.query = "new query"
        await gate.finish()
        await pending.value
        #expect(successes == 0)
        #expect(model.selectedID == nil)
        #expect(model.selectionError == nil)
    }
}

private actor SearchSelectionGate {
    private var read: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func open() async -> Bool {
        await withCheckedContinuation { read = $0; waiter?.resume(); waiter = nil }
    }
    func waitForOpen() async {
        if read != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { read?.resume(returning: true); read = nil }
}

private actor SearchReadGate {
    private var reads: [String: CheckedContinuation<ConversationSummaryPage, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func read(_ query: String) async -> ConversationSummaryPage {
        await withCheckedContinuation { continuation in
            reads[query] = continuation
            waiters.removeValue(forKey: query)?.resume()
        }
    }

    func waitForRead(_ query: String) async {
        if reads[query] != nil { return }
        await withCheckedContinuation { waiters[query] = $0 }
    }

    func finish(_ query: String, page: ConversationSummaryPage) {
        reads.removeValue(forKey: query)?.resume(returning: page)
    }
}
