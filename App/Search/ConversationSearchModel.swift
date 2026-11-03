import Foundation
import Observation

@MainActor
@Observable
final class ConversationSearchModel {
    typealias Reader = @Sendable (String, Int, ConversationSummaryCursor?) async throws -> ConversationSearchPage
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            invalidate()
            items = []; nextCursor = nil; errorMessage = nil; selectionError = nil
        }
    }
    private(set) var items: [ConversationSearchResult] = []
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
    @ObservationIgnored private var worker: Task<ConversationSearchPage, Error>?
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

@MainActor
@Observable
final class ConversationSemanticSearchModel {
    typealias Reader = @Sendable (String, ProviderInstanceID) async throws -> ConversationSearchPage
    typealias AccountResolver = @MainActor () -> ProviderInstanceID?
    typealias EndpointResolver = @MainActor (ProviderInstanceID) -> String?

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            invalidate()
            items = []; errorMessage = nil; selectionError = nil
        }
    }
    private(set) var items: [ConversationSearchResult] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var selectionError: String?
    private(set) var selectedID: String?
    private(set) var endpointAddress: String?
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let selectedAccount: AccountResolver
    @ObservationIgnored private let selectedEndpointAddress: EndpointResolver
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var worker: Task<ConversationSearchPage, Error>?
    @ObservationIgnored private var selection: Task<Void, Never>?
    @ObservationIgnored private var selectionID: UUID?

    init(selectedAccount: @escaping AccountResolver,
         selectedEndpointAddress: @escaping EndpointResolver = { _ in nil },
         reader: @escaping Reader) {
        self.selectedAccount = selectedAccount
        self.selectedEndpointAddress = selectedEndpointAddress
        self.reader = reader
    }

    func refreshEndpointAddress() {
        guard let account = selectedAccount() else {
            endpointAddress = nil
            return
        }
        endpointAddress = selectedEndpointAddress(account)
    }

    func submit() async {
        guard !isLoading else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let account = selectedAccount() else {
            endpointAddress = nil
            items = []
            errorMessage = "请先在设置中选择已配置凭据的 OpenAI 账户。"
            return
        }
        guard let endpointAddress = selectedEndpointAddress(account) else {
            self.endpointAddress = nil
            items = []
            errorMessage = "当前 OpenAI 请求地址无法读取，未发送查询和会话内容。"
            return
        }
        self.endpointAddress = endpointAddress

        let generation = generation
        let id = UUID()
        worker?.cancel()
        operation = id; isLoading = true; errorMessage = nil; selectionError = nil
        let reader = reader
        let pending = Task.detached { try await reader(query, account) }
        worker = pending
        defer {
            if operation == id {
                operation = nil; worker = nil; isLoading = false
            }
        }
        do {
            let page = try await withTaskCancellationHandler { try await pending.value } onCancel: {
                pending.cancel()
            }
            try Task.checkCancellation()
            guard self.generation == generation, operation == id else { return }
            items = page.items
        } catch {
            guard self.generation == generation, operation == id,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = Self.message(for: error)
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

    private static func message(for error: Error) -> String {
        switch error as? ConversationSemanticSearchFailure {
        case .providerUnavailable:
            return "语义搜索服务当前不可用。"
        case .accountUnavailable:
            return "所选 OpenAI 账户不可用，请到设置中重新选择。"
        case .credentialMissing:
            return "所选 OpenAI 账户尚未配置凭据。"
        case .credentialUnavailable:
            return "OpenAI 凭据暂时无法读取，请稍后重试。"
        case .credentialRejected:
            return "OpenAI 凭据需要重新验证。"
        case .queryTooLong:
            return "查询内容过长，请缩短后重试。"
        case .storageUnavailable:
            return "本地语义索引暂时不可用，请重试。"
        case .providerRequestFailed:
            return "OpenAI 语义搜索请求失败，请检查网络和账户后重试。"
        case .invalidEmbedding:
            return "OpenAI 返回的向量格式无法使用。"
        case nil:
            return "语义搜索失败，请重试。"
        }
    }
}
