import Foundation
import UIKit
import Testing
@testable import ZenAgent

@Suite("App Space one-neighbor browse")
struct AppSpaceBrowseTests {
    private let current = AppSpaceGeometry.Item.conversation("current")
    private let older = AppSpaceGeometry.Item.conversation("older")
    private let newer = AppSpaceGeometry.Item.conversation("newer")

    @Test(arguments: [5.0, 160.0, 30_000.0])
    func displacementIsBounded(distance: Double) throws {
        var state = AppSpaceBrowseState(selected: current, older: older, newer: newer)
        let operation1 = state.begin()
        #expect(operation1)
        let operation2 = state.drag(displacement: distance, travel: 300)
        #expect(operation2)
        #expect(state.offset >= 0 && state.offset <= 1)
        let operation3 = state.end(velocity: 0, travel: 300)
        let settlement = try #require(operation3)
        #expect(settlement.destination == (distance == 5 ? current : older))
        #expect(state.selected == current, "selection commits only at accepted completion")
        let operation4 = state.complete(settlement, finished: true)
        #expect(operation4)
        #expect(state.selected == settlement.destination && state.offset == 0)
        let operation5 = !state.complete(settlement, finished: true)
        #expect(operation5)
    }

    @Test func releaseVelocityCanReverseAndNeverSkip() throws {
        var state = AppSpaceBrowseState(selected: current, older: older, newer: newer)
        let operation6 = state.begin()
        #expect(operation6)
        let operation7 = state.drag(displacement: 130, travel: 300)
        #expect(operation7)
        let operation8 = state.end(velocity: -3_000, travel: 300)
        let reversed = try #require(operation8)
        #expect(reversed.destination == newer)
        let operation9 = state.complete(reversed, finished: true)
        #expect(operation9)
        #expect(state.selected == newer)
    }

    @Test(arguments: [false, true])
    func boundariesAndCancelledSettlementHaveNoCommit(atOlderEdge: Bool) throws {
        var state = AppSpaceBrowseState(selected: current,
            older: atOlderEdge ? nil : older, newer: atOlderEdge ? newer : nil)
        let operation10 = state.begin()
        #expect(operation10)
        let operation11 = state.drag(displacement: atOlderEdge ? 10_000 : -10_000, travel: 300)
        #expect(operation11)
        let operation12 = state.end(velocity: atOlderEdge ? 100_000 : -100_000, travel: 300)
        let bounded = try #require(operation12)
        #expect(bounded.destination == current)
        state.cancel()
        let operation13 = !state.complete(bounded, finished: true)
        #expect(operation13)
        #expect(state.selected == current && state.offset == 0 && state.phase == .idle)
        let operation14 = state.begin()
        #expect(operation14)
        let operation15 = state.drag(displacement: atOlderEdge ? -200 : 200, travel: 300)
        #expect(operation15)
        let operation16 = state.end(velocity: 0, travel: 300, cancelled: true)
        let cancelled = try #require(operation16)
        #expect(cancelled.destination == current)
        let operation17 = state.complete(cancelled, finished: false)
        #expect(operation17)
        #expect(state.selected == current && state.phase == .idle)
    }

    @Test func invalidInputAndObsoleteCompletionDoNotAdvance() throws {
        var state = AppSpaceBrowseState(selected: current, older: older, newer: newer)
        let operation18 = state.begin()
        #expect(operation18)
        for travel in [0.0, -1, .nan, .infinity] {
            let operation19 = !state.drag(displacement: 200, travel: travel)
            #expect(operation19)
            let operation20 = state.end(velocity: 0, travel: travel) == nil
            #expect(operation20)
        }
        let operation21 = !state.drag(displacement: .nan, travel: 300)
        #expect(operation21)
        let operation22 = state.end(velocity: .infinity, travel: 300) == nil
        #expect(operation22)
        let operation23 = state.drag(displacement: 200, travel: 300)
        #expect(operation23)
        let operation24 = state.end(velocity: 0, travel: 300)
        let old = try #require(operation24)
        let operation25 = !state.begin()
        #expect(operation25)
        state.cancel()
        let operation26 = state.begin()
        #expect(operation26)
        let operation27 = state.drag(displacement: -200, travel: 300)
        #expect(operation27)
        let operation28 = state.end(velocity: 0, travel: 300)
        let replacement = try #require(operation28)
        let operation29 = !state.complete(old, finished: true)
        #expect(operation29)
        let operation30 = state.complete(replacement, finished: true)
        #expect(operation30)
        #expect(state.selected == newer)
    }

    @Test func depthStackInterpolatesTogetherWithoutChangingLogicalOrder() throws {
        let ids = ["deep3", "deep2", "older", "current", "newer"]
        let size = CGSize(width: 400, height: 800)
        let safe = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        func layout(_ offset: Double) throws -> AppSpaceBrowseGeometry.Layout {
            try #require(AppSpaceBrowseGeometry.resolve(size: size, safeArea: safe,
                historyIDs: ids, current: current, offset: offset,
                minimumCardSize: CGSize(width: 220, height: 300)))
        }
        let idle = try layout(0)
        let half = try layout(0.5)
        let end = try layout(1)
        #expect(idle.cards.count <= 5 && half.cards.count <= 5 && end.cards.count <= 5)
        for item in [current, older, AppSpaceGeometry.Item.conversation("deep2")] {
            let a = try #require(idle.cards.first { $0.item == item })
            let b = try #require(half.cards.first { $0.item == item })
            let c = try #require(end.cards.first { $0.item == item })
            #expect(abs(b.frame.midX - (a.frame.midX + c.frame.midX) / 2) < 0.001)
            #expect(abs(b.frame.width - (a.frame.width + c.frame.width) / 2) < 0.001)
            #expect(AppSpaceBrowseGeometry.pose(for: b, size: size, safeArea: safe)?.isValid == true)
        }
        let incoming = try #require(end.cards.first { $0.item == older })
        let resting = try #require(idle.cards.first { $0.item == current })
        #expect(incoming.frame == resting.frame)
        #expect(resting.frame.midX > size.width / 2)
        #expect(AppSpaceBrowseGeometry.resolve(size: .zero, safeArea: safe,
            historyIDs: ids, current: current, offset: 0, minimumCardSize: size) == nil)
        #expect(AppSpaceBrowseGeometry.resolve(size: size, safeArea: safe,
            historyIDs: ids, current: current, offset: .nan, minimumCardSize: size) == nil)
    }
}
