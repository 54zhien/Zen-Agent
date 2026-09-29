import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppSpaceBrowseController {
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
        return isNewEntry ? nil : originID
    }
    @ObservationIgnored private var reader: Reader?
    @ObservationIgnored private var newReader: (() throws -> ConversationBrowseWindow)?
    @ObservationIgnored var onChanged: (() -> Void)?
    @ObservationIgnored var onOpenActions: (() -> Bool)?
    private(set) var interactionSuspended = false

    var supportsNewEntry: Bool { newReader != nil }
    var isNewEntry: Bool { supportsNewEntry && state.selected == .newConversation }
    func configureNewEntry(reader: @escaping () throws -> ConversationBrowseWindow) { newReader = reader }
    @discardableResult
    func selectCreatedConversation(id: String) -> Bool {
        guard isPresented else { return false }
        cancel()
        do {
            install(try read(id: id, allowsMissing: false))
            errorMessage = nil
            onChanged?()
            return true
        } catch {
            errorMessage = "新会话已创建，但预览读取失败。请重试。"
            onChanged?()
            return false
        }
    }

    func setInteractionSuspended(_ value: Bool) {
        guard interactionSuspended != value else { return }
        if value { cancel() }
        interactionSuspended = value
        onChanged?()
    }

    init(reader: Reader? = nil) { self.reader = reader }
    func configure(reader: @escaping Reader) { self.reader = reader }

    func present(originID: String, fallback: [ConversationSummary] = []) {
        cancel()
        interactionSuspended = false
        self.originID = originID
        isPresented = true
        let current = fallback.first { $0.id == originID }
        originWasNew = current == nil
        install(ConversationBrowseWindow(current: current,
            older: Array(fallback.filter { $0.id != originID }.prefix(3)), newer: nil))
        refresh()
    }

    func refresh() {
        guard isPresented, !interactionSuspended, state.phase == .idle else { return }
        do {
            if isNewEntry { install(try readNew(), selectingNew: true) }
            else if let id = selectedConversationID {
                install(try read(id: id, allowsMissing: id == originID && originWasNew))
            }
            errorMessage = nil
        } catch {
            // A failed refresh is not an empty history or a new page.
            errorMessage = "会话预览读取失败，请重试。"
        }
        onChanged?()
    }

    func begin() -> Bool {
        guard isPresented, !interactionSuspended else { return false }
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
            if supportsNewEntry {
                do {
                    let next = try readNew()
                    guard state.complete(settlement, finished: true) else { return false }
                    install(next, selectingNew: true)
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
            guard originWasNew, let originID else { cancel(); return false }
            id = originID
        }
        do {
            let next = try read(id: id, allowsMissing: settlement.destination == .newConversation || (originWasNew && id == originID))
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

    func cancel() {
        // Native Composer readiness can invalidate Lift on every update. An idle
        // browse cancellation must not publish another observed update back to it.
        guard state.phase != .idle || state.pendingSettlement != nil || state.offset != 0 else { return }
        state.cancel()
        onChanged?()
    }
    func finish() {
        cancel()
        isPresented = false
        interactionSuspended = false
        originID = nil
        originWasNew = false
        window = ConversationBrowseWindow(current: nil, older: [], newer: nil)
        state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
        errorMessage = nil
        onChanged?()
    }

    func updateViewport(size: CGSize, safeArea: UIEdgeInsets) {
        guard size != viewportSize || safeArea != self.safeArea else { return }
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
        var ids = window.older.reversed().map(\.id)
            + (window.current.map { [$0.id] } ?? []) + (window.newer.map { [$0.id] } ?? [])
        if supportsNewEntry, let originID, originWasNew,
           state.selected == .conversation(originID) || state.newer == .conversation(originID), !ids.contains(originID) {
            ids.append(originID)
        }
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

    private func readNew() throws -> ConversationBrowseWindow {
        guard let newReader else { throw PersistenceError.invalidTransition("New entry is unavailable") }
        let next = try newReader()
        guard next.current == nil, next.newer == nil, next.older.count <= 3,
              Set(next.older.map(\.id)).count == next.older.count else {
            throw PersistenceError.invalidTransition("Invalid New neighborhood")
        }
        return next
    }

    private func install(_ next: ConversationBrowseWindow, selectingNew: Bool = false) {
        window = next
        if next.current?.id == originID { originWasNew = false }
        if selectingNew { originWasNew = next.uncommittedOriginID == originID }
        let selected = selectingNew ? AppSpaceGeometry.Item.newConversation
            : next.current.map { .conversation($0.id) }
                ?? (supportsNewEntry && originWasNew ? .conversation(originID ?? "") : .newConversation)
        let newer: AppSpaceGeometry.Item?
        if selectingNew { newer = nil }
        else if let row = next.newer { newer = .conversation(row.id) }
        else if supportsNewEntry {
            newer = originWasNew && selected != .conversation(originID ?? "")
                ? originID.map { .conversation($0) } : .newConversation
        } else { newer = originWasNew && selected != .newConversation ? .newConversation : nil }
        state = AppSpaceBrowseState(selected: selected,
            older: next.older.first.map { .conversation($0.id) }, newer: newer)
    }
}
