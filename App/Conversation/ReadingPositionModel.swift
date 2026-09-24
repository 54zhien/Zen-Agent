/// 视口与内容的几何关系。纯数据，不做单位假设（一律 Double）。
struct ScrollGeometry: Equatable, Sendable {
    let viewportHeight: Double
    let contentHeight: Double
    /// 内容坐标系里的当前滚动偏移（视口顶部对应的内容 y）。
    let offset: Double

    /// 距底部的距离。内容比视口短时为负值，不算「不在底部」。
    var distanceFromBottom: Double { contentHeight - viewportHeight - offset }

    /// anchor 的捕获与恢复都要除以 `viewportHeight`，所以这个值必须为正。
    /// 非正（尚未布局完成、Pane 高度还不是正数）时 anchor 不可捕获，
    /// 不得产生 NaN 或 ±infinity —— 那会把「没有视口」伪装成一个合法比例。
    var isUsableForAnchor: Bool { viewportHeight > 0 }
}

/// Turn 内条目的身份目前是数组下标（`ForEach(..., id: \.offset)`）。
/// 下标不足以作为长期 anchor 身份：将来若插入 reasoning / toolCall 或发生重排，下标会变。
/// 因此本项只做 Turn 级定位：anchor 指向某个 Turn，再加一个该 Turn 相对视口的垂直比例。
/// 本项不声称实现了完整的 item-level anchor。
///
/// Turn 粒度的阅读锚点。
///
/// `relativeViewportOffset = (turnTop - offset) / viewportHeight`，
/// 即「该 Turn 顶部相对视口顶部的位置比例」。
///
/// **不夹到 [0, 1]**：用户在长 Turn 内部阅读时，该 Turn 的顶部在视口之上，
/// 这个值是负数。夹到 0 会让恢复时把 Turn 顶部挪到视口顶部 —— 那正是本项要消除的跳位。
struct TurnAnchor: Equatable, Sendable {
    let runID: String
    let relativeViewportOffset: Double
}

/// 底边锚点：视口底边相对某个 Turn 顶部的距离（点）。
/// 与 TurnAnchor（视口顶部比例）并存，语义不同 —— 它是「视口底边指向内容的哪一处」。
struct BottomTurnAnchor: Equatable, Sendable {
    let runID: String
    let bottomEdgeFromTurnTop: Double
}

/// 阅读模式。**两态**，不是三态。
///
/// 计数用 `Set<String>` 而不是整数：streaming 期间同一个 Turn 会反复变化，
/// 按 Turn 去重才不会让胶囊计数随 delta 数上涨。
enum ReadingMode: Equatable, Sendable {
    case followingBottom
    case reading(anchor: TurnAnchor, pendingTurns: Set<String>)
}

/// 视图层被要求做的事。
enum ScrollAction: Equatable, Sendable {
    case none
    case scrollToBottom
    case restoreAnchor(TurnAnchor)
    case maintainBottomEdge(targetOffset: Double)
}

/// anchor 的可解析性。
enum AnchorResolution: Equatable, Sendable {
    case restore(TurnAnchor)
    case fallbackToBottom
}

/// 滚动/内容变化的输入。事件类型本身就带来源，这是刻意的：
/// 纯逻辑无法从偏移量区分「用户拖动」与「程序滚动」，靠几何推断一定会误判。
enum ReadingPositionEvent: Equatable, Sendable {
    /// 用户手势造成的滚动。`anchor` 由视图层测量（视口顶部那个 Turn），可能为 nil。
    case userScrolled(geometry: ScrollGeometry, anchor: TurnAnchor?)
    /// 程序造成的滚动（本项自己发出的动作的回执）。
    case programmaticScrolled(geometry: ScrollGeometry)
    /// 内容变化，带本次实际重建的 runID 集合（第 3 项 `consume` 的返回值）。
    case contentChanged(changedRunIDs: Set<String>)
    /// 布局变化（Dynamic Type、键盘），内容没变。
    /// 只表示非用户手势导致的布局变化；用户拖动必须发 `userScrolled`。
    case geometryChanged(geometry: ScrollGeometry, anchor: TurnAnchor?)
    /// 单 Pane 高度变化：anchor 是变化前捕获并在连续变化中原样沿用的底边锚点，turnTop 是变化后同一 Turn 的顶部位置。
    case paneHeightChanged(geometry: ScrollGeometry, anchor: BottomTurnAnchor?, turnTop: Double?)
    /// 用户点了「有新内容」胶囊。
    case tappedNewContent
}

struct ReadingPositionOutput: Equatable, Sendable {
    let mode: ReadingMode
    let action: ScrollAction
    let showsNewContentCapsule: Bool
    let newContentCount: Int
}

enum BottomDetector {
    /// `distanceFromBottom <= tolerance` 即为在底部。
    /// 内容短于视口时 `distanceFromBottom` 为负，返回 true（本来就在底部）。
    static func isAtBottom(geometry: ScrollGeometry, tolerance: Double) -> Bool {
        geometry.distanceFromBottom <= tolerance
    }
}

enum NewContentIndicator {
    /// 仅在 `reading` 且 `pendingTurns` 非空时为 true。
    static func isVisible(mode: ReadingMode) -> Bool {
        guard case let .reading(_, pendingTurns) = mode else { return false }
        return !pendingTurns.isEmpty
    }

    /// `followingBottom` 时为 0；否则为 `pendingTurns.count`（去重后的 Turn 数）。
    static func count(mode: ReadingMode) -> Int {
        guard case let .reading(_, pendingTurns) = mode else { return 0 }
        return pendingTurns.count
    }
}
