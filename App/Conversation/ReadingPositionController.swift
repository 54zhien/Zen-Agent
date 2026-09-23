import Observation

@Observable
@MainActor
final class ReadingPositionController {
    private(set) var mode: ReadingMode
    private let stateMachine: ReadingPositionStateMachine

    /// `12` points is an initial value for tolerance and must be calibrated on a real device;
    /// it is not a conclusion derived from a measurement.
    init(tolerance: Double = 12) {
        self.mode = .followingBottom
        self.stateMachine = ReadingPositionStateMachine(tolerance: tolerance)
    }

    /// 施加一个事件，返回该做什么；controller 自己持有 mode。
    func apply(_ event: ReadingPositionEvent) -> ReadingPositionOutput {
        let output = stateMachine.reduce(mode, event)
        mode = output.mode
        return output
    }

    /// 与第 3 项的接口：把 `LiveConversationStore.consume(_:)` 的返回值送进来。
    /// 语义上等价于 `apply(.contentChanged(changedRunIDs:))`。
    @discardableResult
    func applyStoreChanges(_ changedRunIDs: Set<String>) -> ReadingPositionOutput {
        apply(.contentChanged(changedRunIDs: changedRunIDs))
    }

    var showsNewContentCapsule: Bool {
        NewContentIndicator.isVisible(mode: mode)
    }

    var newContentCount: Int {
        NewContentIndicator.count(mode: mode)
    }
}
