import UIKit

enum AppSpaceGeometry {
    enum Item: Hashable, Sendable {
        case conversation(String)
        case newConversation
    }

    struct Placement: Equatable, Sendable {
        let item: Item
        let frame: CGRect
        let depth: Int
        let cornerRadius: CGFloat
    }

    struct Layout: Equatable, Sendable {
        let safeViewport: CGRect
        let logicalOrder: [Item]
        let cards: [Placement]
    }

    static func resolve(size: CGSize, safeArea: UIEdgeInsets, historyIDs: [String],
                        current: Item, minimumCardSize: CGSize) -> Layout? {
        // Deliberate compilable RED mutation: centered full-size cards, no depth,
        // wrong sentinel order and no validation. Replaced only after real CI RED.
        let items = historyIDs.map(Item.conversation) + [.newConversation]
        let frame = CGRect(origin: .zero, size: size)
        return Layout(safeViewport: frame,
                      logicalOrder: [.newConversation] + historyIDs.map(Item.conversation),
                      cards: items.map { Placement(item: $0, frame: frame, depth: 0, cornerRadius: 0) })
    }
}
