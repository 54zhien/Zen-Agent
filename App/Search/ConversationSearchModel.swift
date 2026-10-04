import Foundation
import Observation

@MainActor
@Observable
final class ConversationSearchModel {
    typealias Reader = @Sendable (String, Int, ConversationSummaryCursor?) async throws -> ConversationSummaryPage
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            invalidate()
            items = []; nextCursor = nil; errorMessage = nil; selectionError = nil
        }
    }
    private(set) var items: [ConversationSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var selectionError: String?
    private(set) var selectedID: String?
    private var nextCursor: ConversationSummaryCursor?
    var hasMore: Bool { nextCursor != nil }
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var worker: Task<ConversationSummaryPage, Error>?
    @ObservationIgnored private var selection: Task<Void, Never>?
    @ObservationIgnored private var selectionID: UUID?

    init(debounce: Duration = .milliseconds(180), reader: @escaping Reader) {
        self.debounce = debounce; self.reader = reader
    }

    convenience init(store: PersistenceStore) {
        self.init { query, limit, cursor in
            try await store.searchConversationSummariesAsync(query: query, limit: limit, after: cursor)
        }
    }

    func refresh() async {
        await read(after: nil, delays: true)
    }

    func loadMore() async {
        guard let nextCursor, !isLoading else { return }
        await read(after: nextCursor, delays: false)
    }

    private func read(after cursor: ConversationSummaryCursor?, delays: Bool) async {
        let generation = generation
        let query = query
        guard !query.split(whereSeparator: \.isWhitespace).isEmpty else { isLoading = false; return }
        let id = UUID()
        worker?.cancel()
        operation = id; isLoading = true; errorMessage = nil
        let reader = reader
        let delay = delays ? debounce : .zero
        let pending = Task {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            return try await reader(query, 50, cursor)
        }
        worker = pending
        defer { if operation == id { operation = nil; worker = nil; isLoading = false } }
        do {
            let page = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
            try Task.checkCancellation()
            guard self.generation == generation, operation == id else { return }
            let existing = cursor == nil ? Set<String>() : Set(items.map(\.id))
            let added = page.items.filter { !existing.contains($0.id) }
            items = cursor == nil ? added : items + added
            nextCursor = page.nextCursor
        } catch {
            guard self.generation == generation, operation == id,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "搜索读取失败，请重试。"
        }
    }

    @discardableResult
    func select(_ id: String, open: @escaping @MainActor (String) async -> Bool,
                onSuccess: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        selection?.cancel()
        let ticket = UUID()
        selectionID = ticket; selectedID = id; selectionError = nil
        let pending = Task { [weak self] in
            let opened = await open(id)
            guard let self, !Task.isCancelled, self.selectionID == ticket else { return }
            self.selection = nil; self.selectionID = nil; self.selectedID = nil
            if opened { onSuccess() }
            else { self.selectionError = "会话已不可用或读取失败，原会话已保留。" }
        }
        selection = pending
        return pending
    }

    func invalidate() {
        generation = UUID(); operation = nil; isLoading = false
        worker?.cancel(); worker = nil
        selection?.cancel(); selection = nil; selectionID = nil; selectedID = nil
    }
}
