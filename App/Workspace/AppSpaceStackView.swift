import SwiftUI
import UIKit

/// Only this layer observes display-frame motion; its retained Surface input
/// is built by Workspace independently of the card transport.
@MainActor
struct AppSpaceStackView<Surface: View>: View {
    let model: AppShellModel?
    let browse: AppSpaceBrowseController
    let lift: SurfaceLiftController
    @Binding var requestedMenuID: String?
    let surface: Surface

    init(model: AppShellModel?, browse: AppSpaceBrowseController, lift: SurfaceLiftController,
         requestedMenuID: Binding<String?>, @ViewBuilder surface: () -> Surface) {
        self.model = model
        self.browse = browse
        self.lift = lift
        _requestedMenuID = requestedMenuID
        self.surface = surface()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppSpaceInkView(appearance: model?.appearance,
                isAppSpace: [.lifting, .settling, .card].contains(lift.state.phase),
                displacement: browse.frames.offset * Double(browse.frames.layout?.travel ?? 0))
            if model?.previewContent.isPresented == true, let layout = browse.frames.layout {
                ForEach(layout.cards.filter { $0.item != browse.selected }
                    .map { browse.deletionProjection($0, in: layout) }, id: \.item) { card in
                    projectedCard(card)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .opacity(card.opacity)
                        .position(x: card.frame.midX, y: card.frame.midY)
                        .zIndex(4 - card.depth)
                }
                ForEach(cardTitleSlots(in: layout), id: \.item) { slot in
                    AppSpaceCardTitle(title: slot.title, isNew: slot.item == .newConversation)
                        .frame(width: slot.frame.width, alignment: .leading)
                        .position(x: slot.frame.midX, y: slot.frame.midY)
                        .opacity(slot.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(4.5)
                }
            }
            surface
                .zIndex(4 - (browse.frames.layout?.cards.first { $0.item == browse.selected }?.depth ?? 0))
            if let model, model.previewContent.isPresented, !browse.isNewEntry, browse.canEditCurrentMetadata,
               let summary = browse.currentSummary,
               let frame = browse.frames.layout?.cards.first(where: { $0.item == browse.selected })?.frame {
                AppSpaceCardActionsView(model: model, browse: browse, lift: lift,
                    summary: summary, requestedID: $requestedMenuID)
                    .position(x: frame.maxX - 24, y: frame.minY + 24)
                    .zIndex(100)
            }
        }
    }

    private func projectedCard(_ card: AppSpaceBrowseGeometry.Card) -> some View {
        let summary: ConversationSummary? = {
            if case .conversation(let id) = card.item { return browse.summaries.first { $0.id == id } }
            return nil
        }()
        let size = browse.viewportSize
        let insets = browse.safeArea
        let pose = AppSpaceBrowseGeometry.pose(for: card, size: size, safeArea: insets)
        // Match the native Current's logical viewport, scaling and crop. Reflowing
        // a predecessor at its thumbnail width would jump its text at commitment.
        return ConversationPreviewView(summary: summary,
            status: summary?.contentUnavailable == true ? .contentUnavailable : .ready,
            isNewEntry: browse.supportsNewEntry && card.item == .newConversation)
            .frame(width: max(1, size.width - insets.left - insets.right),
                height: max(1, size.height - insets.top - insets.bottom))
            .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
            .background(Color(uiColor: .systemBackground))
            .scaleEffect(pose?.scale ?? 1)
            .frame(width: card.frame.width, height: card.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous))
    }

    private struct CardTitleSlot {
        let item: AppSpaceGeometry.Item
        let title: String
        let frame: CGRect
        let opacity: Double
    }

    /// Titles sit above their cards as app names do in the system switcher. A
    /// covered card's title is clipped to the strip of that card still showing.
    private func cardTitleSlots(in layout: AppSpaceBrowseGeometry.Layout) -> [CardTitleSlot] {
        let leadingLimit = browse.safeArea.left + 14
        return layout.cards.compactMap { card in
            guard card.depth > -1, card.depth < 2 else { return nil }
            let cover = layout.cards
                .filter { $0.depth < card.depth - 0.5 && $0.frame.minX > card.frame.minX }
                .map(\.frame.minX).min()
            let start = max(card.frame.minX + 4, leadingLimit)
            let end = min(card.frame.maxX, (cover ?? .infinity) - 10)
            guard end - start > 40 else { return nil }
            let title: String
            switch card.item {
            case .newConversation: title = "新对话"
            case .conversation(let id): title = browse.summaries.first { $0.id == id }?.title ?? ""
            }
            guard !title.isEmpty else { return nil }
            return CardTitleSlot(item: card.item, title: title,
                frame: CGRect(x: start, y: card.frame.minY - 30, width: end - start, height: 22),
                opacity: card.opacity * (card.depth > 0.5 ? 0.8 : 1))
        }
    }

}

/// The small label above an App Space card, like an app's name in the switcher.
@MainActor
private struct AppSpaceCardTitle: View {
    let title: String
    let isNew: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isNew ? "plus.bubble.fill" : "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }
}
