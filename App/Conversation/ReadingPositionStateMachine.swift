enum AnchorResolver {
    /// 捕获：`relativeViewportOffset = (turnTop - geometry.offset) / geometry.viewportHeight`。
    /// 几何不可用时不制造比例；没有正的视口高度就没有可用 anchor。
    static func capture(runID: String, turnTop: Double, geometry: ScrollGeometry) -> TurnAnchor? {
        guard geometry.isUsableForAnchor else { return nil }
        return TurnAnchor(
            runID: runID,
            relativeViewportOffset: (turnTop - geometry.offset) / geometry.viewportHeight
        )
    }

    /// 恢复目标：`turnTop - anchor.relativeViewportOffset * geometry.viewportHeight`。
    /// 与 `capture` 互为逆运算：几何不变时返回值等于捕获时的 `offset`。
    static func restoreTarget(anchor: TurnAnchor, turnTop: Double, geometry: ScrollGeometry) -> Double? {
        guard geometry.isUsableForAnchor else { return nil }
        return turnTop - anchor.relativeViewportOffset * geometry.viewportHeight
    }

    /// 捕获视口底边相对 Turn 顶部的距离：`(offset + viewportHeight) - turnTop`。
    /// 几何、Turn 顶部或任一中间结果无效时不制造底边锚点。
    static func captureBottomAnchor(runID: String, turnTop: Double, geometry: ScrollGeometry) -> BottomTurnAnchor? {
        guard geometry.viewportHeight > 0,
              geometry.viewportHeight.isFinite,
              geometry.contentHeight.isFinite,
              geometry.offset.isFinite,
              turnTop.isFinite else { return nil }

        let viewportBottom = geometry.offset + geometry.viewportHeight
        guard viewportBottom.isFinite else { return nil }

        let bottomEdgeFromTurnTop = viewportBottom - turnTop
        guard bottomEdgeFromTurnTop.isFinite else { return nil }

        return BottomTurnAnchor(runID: runID, bottomEdgeFromTurnTop: bottomEdgeFromTurnTop)
    }

    /// 恢复视口底边锚点：`turnTop + bottomEdgeFromTurnTop - viewportHeight`。
    /// 返回未夹取的目标；滚动边界由状态机按内容高度统一处理。
    static func restoreTargetFromBottomAnchor(
        anchor: BottomTurnAnchor,
        turnTop: Double,
        contentHeight: Double,
        viewportHeight: Double
    ) -> Double? {
        guard contentHeight.isFinite,
              viewportHeight > 0,
              viewportHeight.isFinite,
              turnTop.isFinite,
              anchor.bottomEdgeFromTurnTop.isFinite else { return nil }

        let bottomEdge = turnTop + anchor.bottomEdgeFromTurnTop
        guard bottomEdge.isFinite else { return nil }

        let targetOffset = bottomEdge + viewportHeight // MUTATION
        guard targetOffset.isFinite else { return nil }

        return targetOffset
    }

    /// 锚定的 Turn 还在不在。
    static func resolve(anchor: TurnAnchor, presentRunIDs: Set<String>) -> AnchorResolution {
        presentRunIDs.contains(anchor.runID) ? .restore(anchor) : .fallbackToBottom
    }
}

struct ReadingPositionStateMachine: Sendable {
    let tolerance: Double

    func reduce(_ mode: ReadingMode, _ event: ReadingPositionEvent) -> ReadingPositionOutput {
        let transition: (mode: ReadingMode, action: ScrollAction)

        switch event {
        case let .userScrolled(geometry, anchor):
            switch mode {
            case .followingBottom:
                if BottomDetector.isAtBottom(geometry: geometry, tolerance: tolerance) {
                    transition = (.followingBottom, .none)
                } else if let anchor {
                    transition = (.reading(anchor: anchor, pendingTurns: []), .none)
                } else {
                    transition = (.followingBottom, .none)
                }

            case let .reading(currentAnchor, pendingTurns):
                if BottomDetector.isAtBottom(geometry: geometry, tolerance: tolerance) {
                    transition = (.followingBottom, .none)
                } else if let anchor {
                    transition = (.reading(anchor: anchor, pendingTurns: pendingTurns), .none)
                } else {
                    transition = (.reading(anchor: currentAnchor, pendingTurns: pendingTurns), .none)
                }
            }

        case .programmaticScrolled:
            // The event source, not geometry, owns this distinction. A programmatic
            // acknowledgement must never make an anchor-preserving read look like a user
            // scroll and must therefore never change the mode.
            transition = (mode, .none)

        case let .contentChanged(changedRunIDs):
            // An empty consume result means that no Turn was rebuilt. Scrolling in that
            // case would move the reader even though nothing relevant changed.
            guard !changedRunIDs.isEmpty else {
                return output(mode: mode, action: .none)
            }

            switch mode {
            case .followingBottom:
                transition = (.followingBottom, .scrollToBottom)
            case let .reading(anchor, pendingTurns):
                transition = (
                    .reading(anchor: anchor, pendingTurns: pendingTurns.union(changedRunIDs)),
                    .restoreAnchor(anchor)
                )
            }

        case let .geometryChanged(_, _):
            switch mode {
            case .followingBottom:
                // Layout changes must keep a mode that was following the bottom attached to
                // the bottom; otherwise keyboard or Dynamic Type changes expose a gap.
                transition = (.followingBottom, .scrollToBottom)
            case let .reading(anchor, pendingTurns):
                transition = (.reading(anchor: anchor, pendingTurns: pendingTurns), .restoreAnchor(anchor))
            }

        case let .paneHeightChanged(geometry, anchor, turnTop):
            guard geometry.viewportHeight > 0,
                  geometry.viewportHeight.isFinite,
                  geometry.contentHeight.isFinite,
                  geometry.offset.isFinite else {
                return output(mode: mode, action: .none)
            }

            switch mode {
            case .followingBottom:
                let maximumOffsetValue = geometry.contentHeight - geometry.viewportHeight
                guard maximumOffsetValue.isFinite else {
                    return output(mode: mode, action: .none)
                }

                let targetOffset = max(0, maximumOffsetValue)
                transition = (
                    .followingBottom,
                    .maintainBottomEdge(targetOffset: targetOffset)
                )

            case let .reading(currentAnchor, pendingTurns):
                guard let anchor, let turnTop else {
                    transition = (.reading(anchor: currentAnchor, pendingTurns: pendingTurns), .restoreAnchor(currentAnchor))
                    break
                }

                guard let unclampedOffset = AnchorResolver.restoreTargetFromBottomAnchor(
                    anchor: anchor,
                    turnTop: turnTop,
                    contentHeight: geometry.contentHeight,
                    viewportHeight: geometry.viewportHeight
                ) else {
                    return output(mode: mode, action: .none)
                }

                let maximumOffsetValue = geometry.contentHeight - geometry.viewportHeight
                guard maximumOffsetValue.isFinite else {
                    return output(mode: mode, action: .none)
                }

                let maximumOffset = max(0, maximumOffsetValue)
                let appliedOffset = max(0, min(maximumOffset, unclampedOffset))
                guard appliedOffset.isFinite else {
                    return output(mode: mode, action: .none)
                }

                let anchorDistanceFromAppliedOffset = turnTop - appliedOffset
                guard anchorDistanceFromAppliedOffset.isFinite else {
                    return output(mode: mode, action: .none)
                }

                let updatedRelativeViewportOffset = anchorDistanceFromAppliedOffset / geometry.viewportHeight
                guard updatedRelativeViewportOffset.isFinite else {
                    return output(mode: mode, action: .none)
                }

                let updatedAnchor = TurnAnchor(
                    runID: currentAnchor.runID,
                    relativeViewportOffset: updatedRelativeViewportOffset
                )
                transition = (
                    .reading(anchor: updatedAnchor, pendingTurns: pendingTurns),
                    .maintainBottomEdge(targetOffset: appliedOffset)
                )
            }

        case .tappedNewContent:
            switch mode {
            case .followingBottom:
                transition = (.followingBottom, .none)
            case .reading(_, _):
                transition = (.followingBottom, .scrollToBottom)
            }
        }

        return output(mode: transition.mode, action: transition.action)
    }

    private func output(mode: ReadingMode, action: ScrollAction) -> ReadingPositionOutput {
        ReadingPositionOutput(
            mode: mode,
            action: action,
            showsNewContentCapsule: NewContentIndicator.isVisible(mode: mode),
            newContentCount: NewContentIndicator.count(mode: mode)
        )
    }
}
