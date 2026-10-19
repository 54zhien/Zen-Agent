import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppSpaceBrowseController {
    typealias Reader = (String) throws -> ConversationBrowseWindow
    @ObservationIgnored private(set) var state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
    // Retained content observes semantic changes, rather than every offset mutation.
    private(set) var selected: AppSpaceGeometry.Item = .newConversation
    private(set) var phase: AppSpaceBrowseState.Phase = .idle

    /// Frame observation belongs to the stack, not the retained Workspace content.
    @MainActor
    @Observable
    final class Frames {
        var layout: AppSpaceBrowseGeometry.Layout?
        var offset = 0.0
    }
    let frames = Frames()
    private var window = ConversationBrowseWindow(current: nil, older: [], newer: nil)
    var summaries: [ConversationSummary] { window.summaries }
    private(set) var errorMessage: String?
    private(set) var originID: String?
    private(set) var isPresented = false
    private var originWasNew = false
    private(set) var deletionTarget: AppSpaceGeometry.Item?
    private(set) var deletionProgress = 0.0
    private(set) var viewportSize: CGSize = .zero
    private(set) var safeArea: UIEdgeInsets = .zero
    private(set) var displayCornerRadius: CGFloat = 0
    private var minimumCardSize = CGSize(width: 220, height: 300)
    var currentSummary: ConversationSummary? {
        guard case .conversation(let id) = selected else { return nil }
        return summaries.first { $0.id == id }
    }
    var selectedConversationID: String? {
        if case .conversation(let id) = selected { return id }
        return isNewEntry ? nil : originID
    }
    var canEditCurrentMetadata: Bool {
        guard let id = currentSummary?.id else { return false }
        return !window.uncommittedIDs.contains(id)
    }
    @ObservationIgnored private var reader: Reader?
    @ObservationIgnored private var newReader: (() throws -> ConversationBrowseWindow)?
    @ObservationIgnored var onChanged: (() -> Void)?
    @ObservationIgnored private var transportOwner: UUID?
    @ObservationIgnored var onOpenActions: (() -> Bool)?
    private(set) var interactionSuspended = false

    func claimTransport(_ owner: UUID, onChanged: @escaping () -> Void) {
        transportOwner = owner
        self.onChanged = onChanged
    }

    func ownsTransport(_ owner: UUID) -> Bool { transportOwner == owner }

    func releaseTransport(_ owner: UUID) {
        guard ownsTransport(owner) else { return }
        transportOwner = nil
        onChanged = nil
    }

    var supportsNewEntry: Bool { newReader != nil }
    var isNewEntry: Bool { supportsNewEntry && selected == .newConversation }
    func configureNewEntry(reader: @escaping () throws -> ConversationBrowseWindow) { newReader = reader }
    @discardableResult
    func selectCreatedConversation(id: String) -> Bool {
        guard isPresented else { return false }
        cancel()
        do {
            install(try read(id: id, allowsMissing: false))
            errorMessage = nil
            publish()
            return true
        } catch {
            errorMessage = "新会话已创建，但预览读取失败。请重试。"
            publish()
            return false
        }
    }

    @discardableResult
    func selectAfterDeleting(id: String) -> Bool {
        guard isPresented, selectedConversationID == id else { return false }
        cancel()
        // The first predecessor is already the card immediately behind Current.
        // Only one successor is held, so neither route materializes full history.
        let candidates = window.older.map(\.id) + (window.newer.map { [$0.id] } ?? [])
        for candidate in candidates {
            if let next = try? read(id: candidate, allowsMissing: false) {
                install(next)
                clearDeletionReplacement()
                errorMessage = nil
                publish()
                return true
            }
        }
        do {
            install(try readNew(), selectingNew: true)
            clearDeletionReplacement()
            errorMessage = nil
            publish()
            return true
        } catch {
            // The committed deletion already removed Current from ordinary
            // browsing. Keep a readable New shell while the bounded read retries;
            // retaining the hidden ID would leave gesture and visual owners split.
            install(ConversationBrowseWindow(current: nil, older: [], newer: nil), selectingNew: true)
            clearDeletionReplacement()
            errorMessage = "下一张卡片读取失败。会话已保留在撤销窗口内，请重试。"
            publish()
            return false
        }
    }

    func beginDeletionReplacement(id: String) {
        guard selectedConversationID == id else { return }
        deletionTarget = state.older ?? state.newer
        deletionProgress = 0
        publish()
    }

    func advanceDeletionReplacement() {
        guard deletionTarget != nil else { return }
        deletionProgress = 1
        publish()
    }

    func clearDeletionReplacement() {
        guard deletionTarget != nil || deletionProgress != 0 else { return }
        deletionTarget = nil
        deletionProgress = 0
        publish()
    }

    func deletionProjection(_ card: AppSpaceBrowseGeometry.Card,
                            in layout: AppSpaceBrowseGeometry.Layout) -> AppSpaceBrowseGeometry.Card {
        guard card.item == deletionTarget,
              let current = layout.cards.first(where: { $0.item == state.selected }) else { return card }
        let fraction = CGFloat(min(1, max(0, deletionProgress)))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
        return AppSpaceBrowseGeometry.Card(item: card.item,
            frame: CGRect(x: mix(card.frame.minX, current.frame.minX),
                y: mix(card.frame.minY, current.frame.minY),
                width: mix(card.frame.width, current.frame.width),
                height: mix(card.frame.height, current.frame.height)),
            cornerRadius: mix(card.cornerRadius, current.cornerRadius),
            opacity: Double(mix(CGFloat(card.opacity), 1)),
            depth: Double(mix(CGFloat(card.depth), 0)))
    }

    @discardableResult
    func selectRestoredConversation(id: String) -> Bool {
        guard isPresented else { return false }
        cancel()
        do {
            install(try read(id: id, allowsMissing: false))
            errorMessage = nil
            publish()
            return true
        } catch {
            errorMessage = "已恢复会话，但卡片预览读取失败。请重试。"
            publish()
            return false
        }
    }

    func setInteractionSuspended(_ value: Bool) {
        guard interactionSuspended != value else { return }
        if value { cancel() }
        interactionSuspended = value
        publish()
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
        publish()
    }

    func begin() -> Bool {
        guard isPresented, !interactionSuspended else { return false }
        let accepted = state.begin()
        if accepted { publish() }
        return accepted
    }
    func drag(displacement: Double, travel: Double) -> Bool {
        let accepted = state.drag(displacement: displacement, travel: travel)
        if accepted { publish() }
        return accepted
    }

    /// Advance through adjacent summary windows without mounting full pages or
    /// publishing a transient idle selection between successive card intervals.
    func move(to offset: Double) -> Double? {
        guard isPresented, !interactionSuspended, state.phase == .dragging, offset.isFinite else { return nil }
        var remaining = offset
        do {
            while abs(remaining) >= 1 {
                let direction = remaining > 0 ? 1.0 : -1.0
                guard let destination = direction > 0 ? state.older : state.newer else { break }
                let next = try neighborhood(for: destination)
                install(next.window, selectingNew: next.selectingNew)
                _ = state.begin()
                remaining -= direction
                errorMessage = nil
            }
            _ = state.drag(displacement: remaining, travel: 1)
            publish()
            return remaining
        } catch {
            state.cancel()
            errorMessage = "会话预览读取失败，原卡片已保留。请重试。"
            publish()
            return nil
        }
    }
    func end(velocity: Double, travel: Double, cancelled: Bool = false) -> AppSpaceBrowseState.Settlement? {
        let settlement = state.end(velocity: velocity, travel: travel, cancelled: cancelled)
        if settlement != nil { publish() }
        return settlement
    }
    func complete(_ settlement: AppSpaceBrowseState.Settlement, finished: Bool) -> Bool {
        guard state.pendingSettlement == settlement else { return false }
        if !finished || settlement.destination == state.selected {
            let accepted = state.complete(settlement, finished: finished)
            publish()
            return accepted
        }
        do {
            let next = try neighborhood(for: settlement.destination)
            guard state.complete(settlement, finished: true) else { return false }
            install(next.window, selectingNew: next.selectingNew)
            errorMessage = nil
            publish()
            return true
        } catch {
            state.cancel()
            errorMessage = "会话预览读取失败，原卡片已保留。请重试。"
            publish()
            return false
        }
    }

    private func neighborhood(for destination: AppSpaceGeometry.Item) throws
        -> (window: ConversationBrowseWindow, selectingNew: Bool) {
        let id: String
        switch destination {
        case .conversation(let selected): id = selected
        case .newConversation:
            if supportsNewEntry { return (try readNew(), true) }
            guard originWasNew, let originID else {
                throw PersistenceError.invalidTransition("New entry is unavailable")
            }
            id = originID
        }
        return (try read(id: id, allowsMissing: destination == .newConversation
            || (originWasNew && id == originID)), false)
    }

    func cancel() {
        // Native Composer readiness can invalidate Lift on every update. An idle
        // browse cancellation must not publish another observed update back to it.
        guard state.phase != .idle || state.pendingSettlement != nil || state.offset != 0 else { return }
        state.cancel()
        publish()
    }
    func finish() {
        cancel()
        clearDeletionReplacement()
        isPresented = false
        interactionSuspended = false
        originID = nil
        originWasNew = false
        window = ConversationBrowseWindow(current: nil, older: [], newer: nil)
        state = AppSpaceBrowseState(selected: .newConversation, older: nil, newer: nil)
        errorMessage = nil
        publish()
    }

    func updateViewport(size: CGSize, safeArea: UIEdgeInsets, displayCornerRadius: CGFloat = 0) {
        guard size != viewportSize || safeArea != self.safeArea
                || displayCornerRadius != self.displayCornerRadius else { return }
        state.cancel()
        viewportSize = size
        self.safeArea = safeArea
        self.displayCornerRadius = displayCornerRadius
        publish()
    }
    func updateMinimumCardSize(_ size: CGSize) {
        guard minimumCardSize != size else { return }
        minimumCardSize = size
        state.cancel()
        publish()
    }

    func layout(offset: Double? = nil) -> AppSpaceBrowseGeometry.Layout? {
        guard let offset else { return frames.layout }
        return resolveLayout(offset: offset)
    }

    private func publish() {
        if selected != state.selected { selected = state.selected }
        if phase != state.phase { phase = state.phase }
        frames.layout = resolveLayout(offset: state.offset)
        frames.offset = state.offset
        onChanged?()
    }

    private func resolveLayout(offset: Double) -> AppSpaceBrowseGeometry.Layout? {
        var ids = window.older.reversed().map(\.id)
            + (window.current.map { [$0.id] } ?? []) + (window.newer.map { [$0.id] } ?? [])
        if supportsNewEntry, let originID, originWasNew,
           state.selected == .conversation(originID) || state.newer == .conversation(originID), !ids.contains(originID) {
            ids.append(originID)
        }
        return AppSpaceBrowseGeometry.resolve(size: viewportSize, safeArea: safeArea,
            historyIDs: ids, current: state.selected, offset: offset,
            minimumCardSize: minimumCardSize,
            includesNew: state.selected == .newConversation || state.newer == .newConversation,
            displayCornerRadius: displayCornerRadius)
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
        if self.selected != selected { self.selected = selected }
    }
}
