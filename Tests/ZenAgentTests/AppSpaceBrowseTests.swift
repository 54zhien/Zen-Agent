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
        #expect(state.begin())
        #expect(state.drag(displacement: distance, travel: 300))
        #expect(state.offset >= 0 && state.offset <= 1)
        let settlement = try #require(state.end(velocity: 0, travel: 300))
        #expect(settlement.destination == (distance == 5 ? current : older))
        #expect(state.selected == current, "selection commits only at accepted completion")
        #expect(state.complete(settlement, finished: true))
        #expect(state.selected == settlement.destination && state.offset == 0)
        #expect(!state.complete(settlement, finished: true))
    }

    @Test func releaseVelocityCanReverseAndNeverSkip() throws {
        var state = AppSpaceBrowseState(selected: current, older: older, newer: newer)
        #expect(state.begin())
        #expect(state.drag(displacement: 130, travel: 300))
        let reversed = try #require(state.end(velocity: -3_000, travel: 300))
        #expect(reversed.destination == newer)
        #expect(state.complete(reversed, finished: true))
        #expect(state.selected == newer)
    }

    @Test(arguments: [false, true])
    func boundariesAndCancelledSettlementHaveNoCommit(atOlderEdge: Bool) throws {
        var state = AppSpaceBrowseState(selected: current,
            older: atOlderEdge ? nil : older, newer: atOlderEdge ? newer : nil)
        #expect(state.begin())
        #expect(state.drag(displacement: atOlderEdge ? 10_000 : -10_000, travel: 300))
        let bounded = try #require(state.end(velocity: atOlderEdge ? 100_000 : -100_000, travel: 300))
        #expect(bounded.destination == current)
        state.cancel()
        #expect(!state.complete(bounded, finished: true))
        #expect(state.selected == current && state.offset == 0 && state.phase == .idle)
        #expect(state.begin())
        #expect(state.drag(displacement: atOlderEdge ? -200 : 200, travel: 300))
        let cancelled = try #require(state.end(velocity: 0, travel: 300, cancelled: true))
        #expect(cancelled.destination == current)
        #expect(state.complete(cancelled, finished: false))
        #expect(state.selected == current && state.phase == .idle)
    }

    @Test func invalidInputAndObsoleteCompletionDoNotAdvance() throws {
        var state = AppSpaceBrowseState(selected: current, older: older, newer: newer)
        #expect(state.begin())
        for travel in [0.0, -1, .nan, .infinity] {
            #expect(!state.drag(displacement: 200, travel: travel))
            #expect(state.end(velocity: 0, travel: travel) == nil)
        }
        #expect(!state.drag(displacement: .nan, travel: 300))
        #expect(state.end(velocity: .infinity, travel: 300) == nil)
        #expect(state.drag(displacement: 200, travel: 300))
        let old = try #require(state.end(velocity: 0, travel: 300))
        #expect(!state.begin())
        state.cancel()
        #expect(state.begin())
        #expect(state.drag(displacement: -200, travel: 300))
        let replacement = try #require(state.end(velocity: 0, travel: 300))
        #expect(!state.complete(old, finished: true))
        #expect(state.complete(replacement, finished: true))
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
