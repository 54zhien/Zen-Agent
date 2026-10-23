import Testing
import UIKit
@testable import ZenAgent

@Suite("Composer keyboard anchor observation")
@MainActor
struct ComposerKeyboardAnchorObserverTests {
    @Test("a guide frame change is observed when the root bounds stay fixed")
    func guideFrameChange() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let baselineSubviewCount = root.subviews.count
        let guide = UILayoutGuide()
        root.addLayoutGuide(guide)
        let top = guide.topAnchor.constraint(equalTo: root.topAnchor, constant: 539)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top,
            guide.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        root.layoutIfNeeded()
        let rootBounds = root.bounds
        let initialFrame = CGRect(x: 0, y: 539, width: 402, height: 335)
        var observedFrames: [CGRect] = []
        let observer = ComposerKeyboardAnchorObserver(guide: guide) {
            observedFrames.append(guide.layoutFrame)
        }

        root.layoutIfNeeded()
        #expect(observedFrames.count >= 1, "the probe's initial zero-to-valid frame is observable")
        #expect(observedFrames.last == initialFrame)
        #expect(guide.layoutFrame == initialFrame)

        let probe = root.subviews.last
        #expect(root.subviews.count == baselineSubviewCount + 1)
        #expect(probe?.isHidden == true)
        #expect(probe?.isUserInteractionEnabled == false)
        #expect(probe?.isAccessibilityElement == false)
        #expect(probe?.accessibilityElementsHidden == true)

        let callbacksBeforeGuideChange = observedFrames.count
        let changedFrame = CGRect(x: 0, y: 477, width: 402, height: 397)
        top.constant = 477
        root.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(root.bounds == rootBounds)
        #expect(guide.layoutFrame == changedFrame)
        #expect(observedFrames.count > callbacksBeforeGuideChange)
        #expect(observedFrames.last == changedFrame)

        let callbacksAtStableGeometry = observedFrames.count
        root.layoutIfNeeded()
        #expect(observedFrames.count == callbacksAtStableGeometry)

        observer.invalidate()
        #expect(root.subviews.count == baselineSubviewCount)
        let callbacksAtInvalidation = observedFrames.count
        top.constant = 450
        root.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(observedFrames.count == callbacksAtInvalidation)
        #expect(root.subviews.count == baselineSubviewCount)
    }

    @Test("an origin-only guide change is observed even when its size is unchanged")
    func originOnlyGuideChange() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let baselineSubviewCount = root.subviews.count
        let guide = UILayoutGuide()
        root.addLayoutGuide(guide)
        let top = guide.topAnchor.constraint(equalTo: root.topAnchor, constant: 539)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            guide.heightAnchor.constraint(equalToConstant: 335),
            top
        ])
        root.layoutIfNeeded()
        let initialFrame = CGRect(x: 0, y: 539, width: 402, height: 335)
        var observedFrames: [CGRect] = []
        let observer = ComposerKeyboardAnchorObserver(guide: guide) {
            observedFrames.append(guide.layoutFrame)
        }
        root.layoutIfNeeded()
        #expect(observedFrames.count >= 1)
        #expect(observedFrames.last == initialFrame)

        let callbacksBeforeOriginChange = observedFrames.count
        let changedFrame = CGRect(x: 0, y: 477, width: 402, height: 335)
        top.constant = 477
        root.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(guide.layoutFrame.origin != initialFrame.origin)
        #expect(guide.layoutFrame.size == initialFrame.size)
        #expect(guide.layoutFrame == changedFrame)
        #expect(observedFrames.count > callbacksBeforeOriginChange)
        #expect(observedFrames.last == changedFrame)

        let callbacksAtStableGeometry = observedFrames.count
        root.layoutIfNeeded()
        #expect(observedFrames.count == callbacksAtStableGeometry)

        observer.invalidate()
        #expect(root.subviews.count == baselineSubviewCount)
    }

    @Test("invalidating removes the probe and silences later changes to its old guide")
    func invalidationStopsObservation() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let baselineSubviewCount = root.subviews.count
        let guide = UILayoutGuide()
        root.addLayoutGuide(guide)
        let top = guide.topAnchor.constraint(equalTo: root.topAnchor, constant: 539)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            guide.heightAnchor.constraint(equalToConstant: 335),
            top
        ])
        root.layoutIfNeeded()
        var observedFrames: [CGRect] = []
        let observer = ComposerKeyboardAnchorObserver(guide: guide) {
            observedFrames.append(guide.layoutFrame)
        }
        root.layoutIfNeeded()
        #expect(observedFrames.count >= 1)

        observer.invalidate()
        observer.invalidate()
        #expect(root.subviews.count == baselineSubviewCount)
        let callbacksAtInvalidation = observedFrames.count
        top.constant = 477
        root.setNeedsLayout()
        root.layoutIfNeeded()
        #expect(observedFrames.count == callbacksAtInvalidation)
        #expect(root.subviews.count == baselineSubviewCount)
    }
}
