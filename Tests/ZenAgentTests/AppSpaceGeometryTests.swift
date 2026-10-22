import UIKit
import Testing
@testable import ZenAgent

@Suite("Static App Space geometry")
struct AppSpaceGeometryTests {
    private let ids = ["a", "b", "c", "d"]
    private let minimum = CGSize(width: 220, height: 300)

    @Test func selectedCardIsCenteredWithCloselyStackedPredecessors() throws {
        let layout = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 400, height: 800),
            safeArea: UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40), historyIDs: ids,
            current: .conversation("d"), minimumCardSize: minimum))
        #expect(layout.safeViewport == CGRect(x: 20, y: 10, width: 340, height: 760))
        let current = try #require(layout.cards.first { $0.depth == 0 })
        #expect(current.item == .conversation("d"))
        #expect(abs(current.frame.width - 232.9) < 0.001)
        #expect(abs(current.frame.height - 465.8) < 0.001)
        #expect(abs(current.frame.midX - layout.safeViewport.midX) < 0.001)
        #expect(abs(current.frame.midY - 392) < 0.001)
        #expect(layout.safeViewport.contains(current.frame))
        #expect(layout.cards.map(\.depth) == [3, 2, 1, 0])
        for depth in 1...3 {
            let card = try #require(layout.cards.first { $0.depth == depth })
            #expect(card.item == .conversation(ids[3 - depth]))
            #expect(card.frame.minX < current.frame.minX)
            #expect(abs(card.frame.midY - current.frame.midY) < 0.001)
            let above = try #require(layout.cards.first { $0.depth == depth - 1 })
            #expect(card.frame.width < above.frame.width && card.frame.height < above.frame.height)
            #expect(abs(current.frame.midX - card.frame.midX
                - current.frame.width * AppSpaceGeometry.depthOffset(depth)) < 0.001)
            // Like the system switcher, predecessors may pass the leading edge
            // but always keep a visible strip.
            #expect(card.frame.maxX > layout.safeViewport.minX)
        }
        let first = try #require(layout.cards.first { $0.depth == 1 })
        let exposed = current.frame.minX - first.frame.minX
        #expect(exposed > current.frame.width * 0.14 && exposed < current.frame.width * 0.22)
        #expect(first.frame.minY - current.frame.minY < current.frame.height * 0.04)
    }

    @Test func newIsExactlyOnceAtLogicalRightAndCanBeCurrent() throws {
        let layout = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 400, height: 800), safeArea: .zero,
            historyIDs: ids, current: .newConversation, minimumCardSize: minimum))
        #expect(layout.logicalOrder == ids.map(AppSpaceGeometry.Item.conversation) + [.newConversation])
        #expect(layout.logicalOrder.filter { $0 == .newConversation }.count == 1)
        #expect(layout.cards.last?.item == .newConversation)
        #expect(layout.cards.first { $0.depth == 1 }?.item == .conversation("d"))
        let empty = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 400, height: 800), safeArea: .zero,
            historyIDs: [], current: .newConversation, minimumCardSize: minimum))
        #expect(empty.logicalOrder == [.newConversation])
        #expect(empty.cards.count == 1)
    }

    @Test func selectedIdentityDoesNotReorderHistoryAndBudgetIsBounded() throws {
        let many = (0..<1000).map { "conversation-\($0)" }
        for index in [0, 1, 500, 999] {
            let layout = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 400, height: 800), safeArea: .zero,
                historyIDs: many, current: .conversation(many[index]), minimumCardSize: minimum))
            #expect(layout.logicalOrder == many.map(AppSpaceGeometry.Item.conversation) + [.newConversation])
            #expect(layout.cards.count == min(index + 1, 4))
            #expect(layout.cards.last?.item == .conversation(many[index]))
            #expect(Set(layout.cards.map(\.item)).count == layout.cards.count)
        }
    }

    @Test func typographyMinimumChangesGeometryButCannotEscapeViewport() throws {
        let small = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 300, height: 450), safeArea: .zero,
            historyIDs: ids, current: .conversation("d"), minimumCardSize: minimum))
        let large = try #require(AppSpaceGeometry.resolve(size: CGSize(width: 300, height: 450), safeArea: .zero,
            historyIDs: ids, current: .conversation("d"), minimumCardSize: CGSize(width: 440, height: 600)))
        #expect(large.cards.last!.frame.width > small.cards.last!.frame.width)
        #expect(large.cards.last!.frame.height > small.cards.last!.frame.height)
        #expect(large.safeViewport.contains(large.cards.last!.frame))
        for card in large.cards { #expect(card.frame.maxX > large.safeViewport.minX) }
    }

    @Test(arguments: [CGSize(width: 1, height: 1), CGSize(width: 80, height: 150),
        CGSize(width: 320, height: 640), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 1366)])
    func viewportMatrixStaysFiniteContainedAndOrdered(size: CGSize) throws {
        let insets = UIEdgeInsets(top: size.height * 0.08, left: size.width * 0.04,
                                  bottom: size.height * 0.05, right: size.width * 0.06)
        let layout = try #require(AppSpaceGeometry.resolve(size: size, safeArea: insets,
            historyIDs: ids, current: .newConversation, minimumCardSize: minimum))
        for card in layout.cards {
            let isFinite = [card.frame.minX, card.frame.minY, card.frame.maxX, card.frame.maxY, card.cornerRadius].allSatisfy { $0.isFinite }
            #expect(isFinite)
            #expect(card.frame.width > 0 && card.frame.height > 0)
            #expect(card.cornerRadius >= 0 && card.cornerRadius <= min(card.frame.width, card.frame.height) / 2)
            #expect(card.frame.maxX > layout.safeViewport.minX)
            #expect(card.frame.minY >= layout.safeViewport.minY && card.frame.maxY <= layout.safeViewport.maxY)
        }
        let current = try #require(layout.cards.last)
        #expect(current.depth == 0)
        #expect(layout.safeViewport.contains(current.frame))
        #expect(abs(current.frame.midX - layout.safeViewport.midX) < 0.001)
    }

    @Test func displayCornerMakesCardsConcentricWithTheScreen() throws {
        let size = CGSize(width: 390, height: 844)
        let layout = try #require(AppSpaceGeometry.resolve(size: size, safeArea: .zero, historyIDs: ids,
            current: .conversation("d"), minimumCardSize: minimum, displayCornerRadius: 55))
        let current = try #require(layout.cards.last)
        #expect(abs(current.cornerRadius - 55 * current.frame.width / size.width) < 0.001)
        #expect(resolveRejectsNegativeRadius(size: size))
    }

    private func resolveRejectsNegativeRadius(size: CGSize) -> Bool {
        AppSpaceGeometry.resolve(size: size, safeArea: .zero, historyIDs: ids,
            current: .conversation("d"), minimumCardSize: minimum, displayCornerRadius: -1) == nil
    }

    @Test func invalidInputDoesNotFabricateLayout() {
        func resolve(size: CGSize = CGSize(width: 400, height: 800), safe: UIEdgeInsets = .zero,
                     history: [String] = ["a"], current: AppSpaceGeometry.Item = .conversation("a"),
                     minimumSize: CGSize = CGSize(width: 220, height: 300)) -> AppSpaceGeometry.Layout? {
            AppSpaceGeometry.resolve(size: size, safeArea: safe, historyIDs: history,
                current: current, minimumCardSize: minimumSize)
        }
        #expect(resolve(size: .zero) == nil)
        #expect(resolve(size: CGSize(width: CGFloat.infinity, height: 800)) == nil)
        #expect(resolve(size: CGSize(width: 400, height: CGFloat.nan)) == nil)
        #expect(resolve(safe: UIEdgeInsets(top: -1, left: 0, bottom: 0, right: 0)) == nil)
        #expect(resolve(safe: UIEdgeInsets(top: 800, left: 0, bottom: 0, right: 0)) == nil)
        #expect(resolve(safe: UIEdgeInsets(top: 0, left: CGFloat.infinity, bottom: 0, right: 0)) == nil)
        #expect(resolve(history: ["a", "a"]) == nil)
        #expect(resolve(history: [""]) == nil)
        #expect(resolve(current: .conversation("missing")) == nil)
        #expect(resolve(minimumSize: CGSize(width: -1, height: 300)) == nil)
        #expect(resolve(minimumSize: CGSize(width: 220, height: CGFloat.nan)) == nil)
    }
}
