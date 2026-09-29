import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppSpaceBrowseController {
#if DEBUG
    static var diagnosticsEnabledForTesting = false {
        didSet { if diagnosticsEnabledForTesting { diagnosticCount = 0 } }
    }
    private static var diagnosticCount = 0
    static func trace(_ event: String) {
        guard diagnosticsEnabledForTesting, diagnosticCount < 60 else { return }
        diagnosticCount += 1
        print("S505_BROWSE_TRACE \(event)")
    }
#endif
    typealias Reader = (String) throws -> ConversationBrowseWindow
    private(set) var state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
    private var window = ConversationBrowseWindow(current: nil, older: [], newer: nil)
    var summaries: [ConversationSummary] { window.summaries }
    private(set) var errorMessage: String?
    private(set) var originID: String?
    private(set) var isPresented = false
    private var originWasNew = false
    private(set) var viewportSize: CGSize = .zero
    private(set) var safeArea: UIEdgeInsets = .zero
    private var minimumCardSize = CGSize(width: 220, height: 300)
    var currentSummary: ConversationSummary? {
        guard case .conversation(let id) = state.selected else { return nil }
        return summaries.first { $0.id == id }
    }
    var selectedConversationID: String? {
        if case .conversation(let id) = state.selected { return id }
        return originID
    }
    @ObservationIgnored private var reader: Reader?
    @ObservationIgnored var onChanged: (() -> Void)?

    init(reader: Reader? = nil) { self.reader = reader }
    func configure(reader: @escaping Reader) { self.reader = reader }

    func present(originID: String, fallback: [ConversationSummary] = []) {
        cancel()
        self.originID = originID
        isPresented = true
        let current = fallback.first { $0.id == originID }
        originWasNew = current == nil
        install(ConversationBrowseWindow(current: current,
            older: Array(fallback.filter { $0.id != originID }.prefix(3)), newer: nil))
        refresh()
    }

    func refresh() {
        guard isPresented, state.phase == .idle, let id = selectedConversationID else { return }
        do {
            let next = try read(id: id, allowsMissing: state.selected == .newConversation)
            install(next)
            errorMessage = nil
        } catch {
            // A failed refresh is not an empty history or a new page.
            errorMessage = "会话预览读取失败，请重试。"
        }
        onChanged?()
    }

    func begin() -> Bool {
        guard isPresented else { return false }
        let accepted = state.begin()
        if accepted { onChanged?() }
        return accepted
    }
    func drag(displacement: Double, travel: Double) -> Bool {
        let accepted = state.drag(displacement: displacement, travel: travel)
        if accepted { onChanged?() }
        return accepted
    }
    func end(velocity: Double, travel: Double, cancelled: Bool = false) -> AppSpaceBrowseState.Settlement? {
        let settlement = state.end(velocity: velocity, travel: travel, cancelled: cancelled)
        if settlement != nil { onChanged?() }
        return settlement
    }
    func complete(_ settlement: AppSpaceBrowseState.Settlement, finished: Bool) -> Bool {
        guard state.pendingSettlement == settlement else { return false }
        if !finished || settlement.destination == state.selected {
            let accepted = state.complete(settlement, finished: finished)
            onChanged?()
            return accepted
        }
        let id: String
        switch settlement.destination {
        case .conversation(let selected): id = selected
        case .newConversation:
            guard originWasNew, let originID else { cancel(); return false }
            id = originID
        }
        do {
            let next = try read(id: id, allowsMissing: settlement.destination == .newConversation)
            guard state.complete(settlement, finished: true) else { return false }
            install(next)
            errorMessage = nil
            onChanged?()
            return true
        } catch {
            state.cancel()
            errorMessage = "会话预览读取失败，原卡片已保留。请重试。"
            onChanged?()
            return false
        }
    }

    func cancel() { state.cancel(); onChanged?() }
    func finish() {
        cancel()
        isPresented = false
        originID = nil
        originWasNew = false
        window = ConversationBrowseWindow(current: nil, older: [], newer: nil)
        state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
        errorMessage = nil
        onChanged?()
    }

    func updateViewport(size: CGSize, safeArea: UIEdgeInsets) {
        guard size != viewportSize || safeArea != self.safeArea else { return }
#if DEBUG
        Self.trace("viewport \(size) \(safeArea)")
#endif
        state.cancel()
        viewportSize = size
        self.safeArea = safeArea
        onChanged?()
    }
    func updateMinimumCardSize(_ size: CGSize) {
        minimumCardSize = size
        cancel()
    }

    func layout(offset: Double? = nil) -> AppSpaceBrowseGeometry.Layout? {
        let ids = window.older.reversed().map(\.id)
            + (window.current.map { [$0.id] } ?? []) + (window.newer.map { [$0.id] } ?? [])
        return AppSpaceBrowseGeometry.resolve(size: viewportSize, safeArea: safeArea,
            historyIDs: ids, current: state.selected, offset: offset ?? state.offset,
            minimumCardSize: minimumCardSize,
            includesNew: state.selected == .newConversation || state.newer == .newConversation)
    }

    private func read(id: String, allowsMissing: Bool) throws -> ConversationBrowseWindow {
        guard let reader else { throw PersistenceError.conversationNotFound(id) }
        let next = try reader(id)
        guard next.older.count <= 3, next.summaries.count <= 5,
              Set(next.summaries.map(\.id)).count == next.summaries.count,
              next.current?.id == id || (allowsMissing && next.current == nil) else {
            throw PersistenceError.conversationNotFound(id)
        }
        return next
    }

    private func install(_ next: ConversationBrowseWindow) {
        window = next
        if next.current?.id == originID { originWasNew = false }
        let selected = next.current.map { AppSpaceGeometry.Item.conversation($0.id) } ?? .newConversation
        let newer = next.newer.map { AppSpaceGeometry.Item.conversation($0.id) }
            ?? (originWasNew && selected != .newConversation ? .newConversation : nil)
        state = AppSpaceBrowseState(selected: selected,
            older: next.older.first.map { .conversation($0.id) }, newer: newer)
    }
}
