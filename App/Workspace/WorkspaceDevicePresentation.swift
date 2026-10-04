import UIKit
import SwiftUI
import Observation

enum WorkspaceDevicePresentation: Equatable {
    case single
    case split(SplitWorkspaceAxis)
    case landscapeSingle(SplitDropSlot)

    static func resolve(isPad: Bool, size: CGSize, split: SplitWorkspaceState?) -> Self {
        guard let split else { return .single }
        if !isPad, size.width.isFinite, size.height.isFinite, size.width > size.height {
            return .landscapeSingle(split.activeSlot)
        }
        return .split(isPad ? split.axis : .topBottom)
    }
}

struct WorkspaceLayoutContext: Equatable {
    let windowID: ObjectIdentifier
    let windowSize: CGSize
    /// The already-proposed usable Workspace rectangle, in window coordinates.
    let frame: CGRect
    let isPad: Bool
}

@MainActor
@Observable
final class WorkspaceLayoutState {
    var context: WorkspaceLayoutContext?
}

@MainActor
struct WorkspaceLayoutObserver: UIViewRepresentable {
    let report: (WorkspaceLayoutContext) -> Void
    func makeUIView(context: Context) -> WorkspaceLayoutObserverView {
        let view = WorkspaceLayoutObserverView()
        view.report = report
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WorkspaceLayoutObserverView, context: Context) {
        view.report = report
        view.scheduleReport()
    }
}

@MainActor
final class WorkspaceLayoutObserverView: UIView {
    var report: ((WorkspaceLayoutContext) -> Void)?
    private var generation: UInt64 = 0
    override func layoutSubviews() { super.layoutSubviews(); scheduleReport() }
    override func didMoveToWindow() { super.didMoveToWindow(); scheduleReport() }
    func scheduleReport() {
        generation &+= 1
        let ticket = generation
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.generation == ticket, let window = self.window,
                  self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.report?(WorkspaceLayoutContext(windowID: ObjectIdentifier(window), windowSize: window.bounds.size,
                frame: self.convert(self.bounds, to: window), isPad: self.traitCollection.userInterfaceIdiom == .pad))
        }
    }
}
