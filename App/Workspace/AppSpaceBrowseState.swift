import Foundation

struct AppSpaceBrowseState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, dragging, settling }
    struct Settlement: Equatable, Sendable {
        let identity: UUID
        let destination: AppSpaceGeometry.Item
        let startOffset: Double
        let endOffset: Double
    }
    private(set) var selected: AppSpaceGeometry.Item
    private(set) var older: AppSpaceGeometry.Item?
    private(set) var newer: AppSpaceGeometry.Item?
    private(set) var phase: Phase = .idle
    private(set) var offset: Double = 0
    private(set) var pendingSettlement: Settlement?

    init(selected: AppSpaceGeometry.Item, older: AppSpaceGeometry.Item?, newer: AppSpaceGeometry.Item?) {
        self.selected = selected; self.older = older; self.newer = newer
    }
    mutating func begin() -> Bool { false }
    mutating func drag(displacement: Double, travel: Double) -> Bool { false }
    mutating func end(velocity: Double, travel: Double, cancelled: Bool = false) -> Settlement? { nil }
    mutating func complete(_ settlement: Settlement, finished: Bool) -> Bool { false }
    mutating func cancel() {}
}
