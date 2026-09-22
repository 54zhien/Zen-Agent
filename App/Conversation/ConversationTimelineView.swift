import SwiftUI

/// The conversation reading surface: one Turn after another, read top to bottom.
///
/// Not mounted anywhere. The view's entry point needs the "first launch / zero
/// conversations" decision, which the Blueprint has not settled, so this item builds the
/// surface and deliberately leaves that choice to whoever wires it up.
///
/// The turn boundary is carried by vertical rhythm rather than by a rule or a divider
/// (Blueprint 3.1): the space between Turns is much larger than the space inside one, and
/// nothing is drawn to say where a turn ends.
struct ConversationTimelineView: View {
    let projection: ConversationTimelineProjection

    @ScaledMetric(relativeTo: .body) private var betweenTurns = Metrics.betweenTurns
    @ScaledMetric(relativeTo: .body) private var contentInset = Metrics.contentInset

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: betweenTurns) {
                ForEach(projection.turns) { turn in
                    ConversationTurnView(turn: turn)
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.vertical, betweenTurns)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One Turn, in the order the projection produced.
///
/// Nothing is reordered, grouped or annotated here: the projection already decided what a
/// turn contains and in which order, and a view that second-guessed it would be a second
/// place where the reading order is defined.
private struct ConversationTurnView: View {
    let turn: ConversationTurn

    @ScaledMetric(relativeTo: .body) private var withinTurn = Metrics.withinTurn

    var body: some View {
        VStack(alignment: .leading, spacing: withinTurn) {
            // Items are not `Identifiable` — their identity is their position in this turn,
            // which is what the projection's order means.
            ForEach(Array(turn.items.enumerated()), id: \.offset) { entry in
                TimelineItemView(item: entry.element)
            }
        }
    }
}

/// One line of a Turn.
///
/// Every role below resolves through the Typography token layer, and this view names no
/// face, no point size and no weight of its own. `dynamicTypeSize` is read here so a change
/// to the reader's text size re-derives each of those sizes rather than leaving the layout
/// on a stale one.
private struct TimelineItemView: View {
    let item: TimelineItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var inlineSpacing = Metrics.inlineSpacing
    @ScaledMetric(relativeTo: .body) private var secondaryInset = Metrics.secondaryInset

    @ViewBuilder
    var body: some View {
        switch item {
        case .userText(let text):
            PromptCapsuleView(text: text)

        case .assistantText(let text):
            // No bubble: the assistant's text is the reading body itself.
            Text(text)
                .font(Typography.font(for: .conversationBody, dynamicTypeSize: dynamicTypeSize))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .reasoning(let text):
            Text(text)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
                .lineLimit(Metrics.collapsedSecondaryLines)
                .padding(.leading, secondaryInset)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .toolCall(let call):
            HStack(alignment: .firstTextBaseline, spacing: inlineSpacing) {
                Text(call.action)
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                Text(call.state.rawValue)
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, secondaryInset)

        case .toolResult(let result):
            Text(result.payload)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
                .lineLimit(Metrics.collapsedSecondaryLines)
                .padding(.leading, secondaryInset)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .runNotice(let notice):
            // The words are the state's own token, not display copy. User-facing wording and
            // the Retry entry belong to the Action Row item, and inventing strings here would
            // pre-empt the Blueprint's copy table.
            HStack(alignment: .firstTextBaseline, spacing: inlineSpacing) {
                Text(notice.state.rawValue)
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                if let endReason = notice.endReason {
                    Text(endReason.rawValue)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The user's own message, kept in the same left column as the assistant's text.
///
/// Two lines collapsed, tap to expand the whole message. The expansion is presentation
/// state only — it never touches the stored message, and collapsing it again is not a
/// message edit (Blueprint 3.1).
private struct PromptCapsuleView: View {
    let text: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    @ScaledMetric(relativeTo: .body) private var capsulePadding = Metrics.capsulePadding

    var body: some View {
        Text(text)
            .font(Typography.font(for: .conversationPrompt, dynamicTypeSize: dynamicTypeSize))
            .lineLimit(isExpanded ? nil : Metrics.collapsedPromptLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(capsulePadding)
            // The Blueprint asks for a semantic `userPromptSurface` token with its own light
            // and dark values. That token layer is not this item's job, so the system's
            // semantic background stands in rather than a palette invented here.
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius, style: .continuous))
            .onTapGesture { isExpanded.toggle() }
    }
}

/// Spacing and shape for the reading layout.
///
/// Every number here is a **starting point to calibrate on device, not a measured result** —
/// the Blueprint leaves the reading rhythm to device calibration. The ones used as spacing
/// are applied through `@ScaledMetric` at the call site, so the separation grows with the
/// reader's text size instead of the type crowding together at accessibility sizes.
private enum Metrics {
    /// Between two Turns. Deliberately much larger than the spacing inside one: this gap is
    /// what marks a turn boundary, standing in for a divider.
    static let betweenTurns: CGFloat = 28
    /// Between the items of one Turn — tight enough that they read as one utterance.
    static let withinTurn: CGFloat = 10
    /// Leading inset for secondary content (reasoning, tool activity), which sits under the
    /// text it belongs to rather than beside it.
    static let secondaryInset: CGFloat = 2
    /// Between two things on one line.
    static let inlineSpacing: CGFloat = 8
    /// Screen-edge inset for the whole reading column.
    static let contentInset: CGFloat = 20
    /// Padding inside the user prompt capsule.
    static let capsulePadding: CGFloat = 12
    /// Corner radius of the user prompt capsule. Continuous, so it reads as one soft surface
    /// rather than as four arcs. Not scaled with text: it is a shape, not a distance.
    static let capsuleCornerRadius: CGFloat = 16
    /// A prompt reads as two lines while collapsed; a tap expands it to the whole message.
    static let collapsedPromptLines = 2
    /// Secondary activity collapses to a single line — a pointer to what happened rather than
    /// a summary of it.
    static let collapsedSecondaryLines = 1
}
