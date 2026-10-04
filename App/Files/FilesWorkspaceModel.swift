import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class FilesWorkspaceModel {
    private enum Outcome: Sendable {
        case imported
        case removed(Bool)
        case presentation(ManagedFilePresentation)
    }

    private(set) var items: [FileWorkspaceItem] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    var hasMore: Bool { cursor != nil }
    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let files: ManagedFileStore
    @ObservationIgnored private let sessions: ConversationSessionStore
    @ObservationIgnored private var active = true
    @ObservationIgnored private var cursor: FileWorkspaceCursor?
    @ObservationIgnored private var readID: UUID?
    @ObservationIgnored private var reader: Task<FileWorkspacePage, Error>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var operation: Task<Outcome, Error>?
    @ObservationIgnored private var cancellation: FileOperationCancellation?

    init(store: PersistenceStore, files: ManagedFileStore, sessions: ConversationSessionStore) {
        self.store = store; self.files = files; self.sessions = sessions
    }

    func refresh(clearError: Bool = false) async {
        if clearError { errorMessage = nil }
        await read(after: nil)
    }

    func loadMore() async {
        guard !isLoading, let cursor else { return }
        await read(after: cursor)
    }

    private func read(after previous: FileWorkspaceCursor?) async {
        guard active, !Task.isCancelled else { return }
        reader?.cancel()
        let id = UUID(); readID = id; isLoading = true
        let store = store
        let pending = Task { try await store.fileWorkspacePageAsync(limit: 50, after: previous) }
        reader = pending
        defer { if readID == id { readID = nil; reader = nil; isLoading = false } }
        do {
            let page = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
            guard active, readID == id, !Task.isCancelled else { return }
            let existing = previous == nil ? Set<String>() : Set(items.map(\.id))
            let added = page.items.filter { !existing.contains($0.id) }
            items = previous == nil ? added : items + added
            cursor = page.nextCursor
        } catch {
            guard active, readID == id, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "文件目录读取失败，请重试。"
        }
    }

    func importFile(at url: URL) async {
        let files = files, store = store
        let result = await perform { signal in
            try await Self.detached(signal: signal) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let mediaType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType
                _ = try files.ingest(fileAt: url, displayName: url.lastPathComponent,
                    mediaType: mediaType, in: store, checkCancellation: { try signal.check() })
                return .imported
            }
        }
        if case .some(.imported) = result { await refresh() }
    }

    func removeAsset(id: String) async {
        let files = files, store = store, sessions = sessions
        let result = await perform { signal in
            let removed = try await sessions.withFileRemovalReservation(assetID: id) {
                let result = try await Self.detached(signal: signal) {
                    .removed(try files.removeUnreferencedAsset(id: id, in: store, protectedAssetIDs: [],
                        checkCancellation: { try signal.check() }))
                }
                if case .removed(let value) = result { return value }
                return false
            }
            return .removed(removed)
        }
        if case .some(.removed(let removed)) = result {
            if !removed { errorMessage = "文件仍被会话、草稿或待提交附件使用，无法删除。" }
            await refresh()
        }
    }

    func preparePresentation(id: String) async -> ManagedFilePresentation? {
        guard let item = items.first(where: { $0.id == id }), let attachment = item.attachment else {
            if active { errorMessage = "文件版本信息不可用，目录记录已保留。" }
            return nil
        }
        let files = files, store = store
        let result = await perform { signal in
            try await Self.detached(signal: signal) {
                .presentation(try files.makePresentationCopy(for: attachment, in: store))
            }
        }
        if case .some(.presentation(let copy)) = result { return copy }
        return nil
    }

    private func perform(_ body: @escaping @Sendable (FileOperationCancellation) async throws -> Outcome) async -> Outcome? {
        guard active, !isWorking, !Task.isCancelled else { return nil }
        let id = UUID(), signal = FileOperationCancellation()
        operationID = id; cancellation = signal; isWorking = true; errorMessage = nil
        let pending = Task { try await body(signal) }
        operation = pending
        defer {
            if operationID == id {
                operationID = nil; operation = nil; cancellation = nil; isWorking = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await pending.value } onCancel: {
                signal.cancel(); pending.cancel()
            }
            guard active, operationID == id, !Task.isCancelled else { return nil }
            return result
        } catch {
            guard active, operationID == id, !Task.isCancelled, !(error is CancellationError) else { return nil }
            if case ManagedFileStoreError.missingBlob = error {
                errorMessage = "文件字节已缺失，目录记录已保留。"
            } else if case ManagedFileStoreError.corruptBlob = error {
                errorMessage = "文件校验失败，目录记录已保留。"
            } else {
                errorMessage = "文件操作失败，请检查文件访问权限或可用存储空间后重试。"
            }
            return nil
        }
    }

    nonisolated private static func detached(signal: FileOperationCancellation,
        body: @escaping @Sendable () throws -> Outcome
    ) async throws -> Outcome {
        let pending = Task.detached { try signal.check(); return try body() }
        return try await withTaskCancellationHandler { try await pending.value } onCancel: {
            signal.cancel(); pending.cancel()
        }
    }

    func invalidate() {
        active = false; readID = nil; isLoading = false
        reader?.cancel(); reader = nil
        cancellation?.cancel(); operation?.cancel()
        // Keep operation ownership and isWorking until the actual detached writer drains.
    }
}
