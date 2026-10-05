import Testing
import UIKit
@testable import ZenAgent

@MainActor
private final class DividerInitialTouch: UITouch {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init() }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
private final class DividerSamplePan: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { .zero }
}

@MainActor
@Suite("Divider initial touch displacement", .serialized)
struct SplitDividerInteractionTests {
    @Test(arguments: [SplitWorkspaceAxis.topBottom, .leftRight])
    func coalescedPanRetainsMovementBeforeRecognition(axis: SplitWorkspaceAxis) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let handle = SplitDividerHandle(frame: CGRect(x: 100, y: 300, width: 64, height: 28))
        window.addSubview(handle)
        var moves: [Double] = []
        var endings: [Bool] = []
        handle.configuration = SplitDividerView(ratio: 0.5, closeIntent: nil,
            canCloseTop: true, canCloseBottom: true, onBegin: { true },
            onMove: { moves.append($0) }, onEnd: { endings.append($0) },
            onClose: { _ in }, onAdjust: { _ in }, axis: axis)
        let installed = try #require(handle.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        let origin = CGPoint(x: 132, y: 314)
        let touch = DividerInitialTouch(point: origin)
        #expect(installed.delegate?.gestureRecognizer?(installed, shouldReceive: touch) ?? true)
        let sample = DividerSamplePan()
        sample.point = axis == .leftRight ? CGPoint(x: origin.x + 100, y: origin.y)
            : CGPoint(x: origin.x, y: origin.y + 100)
        sample.sampleState = .began
        _ = handle.perform(NSSelectorFromString("panned:"), with: sample)
        // The moving handle is not the coordinate owner of this gesture.
        handle.frame.origin.x += 70
        handle.frame.origin.y += 50
        sample.sampleState = .ended
        _ = handle.perform(NSSelectorFromString("panned:"), with: sample)
        #expect(moves == [100, 100])
        #expect(endings == [false])
    }
}
